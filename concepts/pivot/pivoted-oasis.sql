-- ------------------------------------------------------------------
-- Title: Oxford Acute Severity of Illness Score (OASIS)
-- This query extracts the Oxford acute severity of illness score.
-- This score is a measure of severity of illness for patients in the ICU.
-- The score is calculated for every hour of the patient's ICU stay.
-- However, as the calculation window is 24 hours, care should be taken when
-- using the score before the end of the first day.
-- ------------------------------------------------------------------

-- Reference for OASIS:
--    Johnson, Alistair EW, Andrew A. Kramer, and Gari D. Clifford.
--    "A new severity of illness scale using a subset of acute physiology and chronic health evaluation data elements shows comparable predictive accuracy*."
--    Critical care medicine 41, no. 7 (2013): 1711-1718.

-- Variables used in OASIS:
--  Heart rate, GCS, MAP, Temperature, Respiratory rate, Ventilation status (sourced from CHARTEVENTS)
--  Urine output (sourced from OUTPUTEVENTS)
--  Elective surgery (sourced from ADMISSIONS and SERVICES)
--  Pre-ICU in-hospital length of stay (sourced from ADMISSIONS and ICUSTAYS)
--  Age (sourced from PATIENTS)

-- The following views are required to run this query:
--  1) uofirstday - generated by urine-output-first-day.sql
--  2) ventfirstday - generated by ventilated-first-day.sql
--  3) vitalsfirstday - generated by vitals-first-day.sql
--  4) gcsfirstday - generated by gcs-first-day.sql


-- Regarding missing values:
--  The ventilation flag is always 0/1. It cannot be missing, since VENT=0 if no data is found for vent settings.

-- Note:
--  The score is calculated for *all* ICU patients, with the assumption 
--  that the user will subselect appropriate ICUSTAY_IDs.
--  For example, the score is calculated for neonates, but it is likely inappropriate to
--  actually use the score values for these patients.

-- The following views required to run this query:
--  1) pivoted_uo - generated by pivoted-uo.sql
--  2) pivoted_lab - generated by pivoted-lab.sql
--  3) pivoted_gcs - generated by pivoted-gcs.sql
--  4) pivoted_vital - generated by pivoted-vital.sql
--  5) ventdurations - generated by ../durations/ventilation-durations.sql

DROP TABLE IF EXISTS pivoted_oasis CASCADE;
CREATE TABLE pivoted_oasis AS
-- generate a row for every hour the patient was in the ICU
WITH co_hours AS
(
  select ih.icustay_id, ie.hadm_id
  , hr
  -- start/endtime can be used to filter to values within this hour
  , DATETIME_SUB(ih.endtime, INTERVAL '1' HOUR) AS starttime
  , ih.endtime
  from `physionet-data.mimiciii_derived.icustay_hours` ih
  INNER JOIN `physionet-data.mimiciii_clinical.icustays` ie
    ON ih.icustay_id = ie.icustay_id
)
, mini_agg as
(
  select co.icustay_id, co.hr
  -- vitals
  , min(v.HeartRate) as HeartRate_min
  , max(v.HeartRate) as HeartRate_max
  , min(v.TempC) as TempC_min
  , max(v.TempC) as TempC_max
  , min(v.MeanBP) as MeanBP_min
  , max(v.MeanBP) as MeanBP_max
  , min(v.RespRate) as RespRate_min
  , max(v.RespRate) as RespRate_max
  -- gcs
  , min(gcs.GCS) as GCS_min
  -- because pafi has an interaction between vent/PaO2:FiO2, we need two columns for the score
  -- it can happen that the lowest unventilated PaO2/FiO2 is 68, but the lowest ventilated PaO2/FiO2 is 120
  -- in this case, the SOFA score is 3, *not* 4.
  , MAX(case
        when vd1.icustay_id is not null then 1 
        when vd2.icustay_id is not null then 1
    else 0 end) AS mechvent
  from co_hours co
  left join pivoted_vitals v
    on co.icustay_id = v.icustay_id
    and co.starttime < v.charttime
    and co.endtime >= v.charttime
  left join pivoted_gcs gcs
    on co.icustay_id = gcs.icustay_id
    and co.starttime < gcs.charttime
    and co.endtime >= gcs.charttime
  -- at the time of this row, was the patient ventilated
  left join ventdurations vd1
    on co.icustay_id = vd.icustay_id
    and co.starttime >= vd.starttime
    and co.starttime <= vd.endtime
  left join ventdurations vd2
    on co.icustay_id = vd.icustay_id
    and co.endtime >= vd.starttime
    and co.endtime <= vd.endtime
  group by co.icustay_id, co.hr
)
-- sum uo separately to prevent duplicating values
, uo as
(
  select co.icustay_id, co.hr
  -- uo
  , sum(uo.urineoutput) as UrineOutput
  from co_hours co
  left join pivoted_uo uo
    on co.icustay_id = uo.icustay_id
    and co.starttime < uo.charttime
    and co.endtime >= uo.charttime
  group by co.icustay_id, co.hr
)
, scorecomp as
(
  select
      co.icustay_id
    , co.hr
    , co.starttime, co.endtime
    , ma.MeanBP_min
    , ma.MeanBP_max
    , ma.HeartRate_min
    , ma.HeartRate_max
    , ma.TempC_min
    , ma.TempC_max
    , ma.RespRate_min
    , ma.RespRate_max
    , ma.GCS_min
    -- uo
    , uo.urineoutput
    -- static variables that do not change over the ICU stay
    , cast(co.intime as timestamp) - cast(adm.admittime as timestamp) as PreICULOS
    , case
        when adm.ADMISSION_TYPE = 'ELECTIVE' and sf.surgical = 1
        then 1
        when adm.ADMISSION_TYPE is null or sf.surgical is null
        then null
        else 0
    end as ElectiveSurgery
  from co_hours co
  inner join admissions adm
    on co.hadm_id = adm.hadm_id
  left join surgflag sf
    on co.icustay_id = sf.icustay_id
  left join mini_agg ma
    on co.icustay_id = ma.icustay_id
    and co.hr = ma.hr
  left join uo
    on co.icustay_id = uo.icustay_id
    and co.hr = uo.hr
)
, scorecalc as
(
  -- Calculate the final score
  -- note that if the underlying data is missing, the component is null
  -- eventually these are treated as 0 (normal), but knowing when data is missing is useful for debugging
  select scorecomp.*
    -- Below code calculates the component scores needed for OASIS
    , case when preiculos is null then null
        when preiculos < '0 0:10:12' then 5
        when preiculos < '0 4:57:00' then 3
        when preiculos < '1 0:00:00' then 0
        when preiculos < '12 23:48:00' then 1
        else 2 end as preiculos_score
    ,  case when age is null then null
        when age < 24 then 0
        when age <= 53 then 3
        when age <= 77 then 6
        when age <= 89 then 9
        when age >= 90 then 7
        else 0 end as age_score
    ,  case when mingcs is null then null
        when mingcs <= 7 then 10
        when mingcs < 14 then 4
        when mingcs = 14 then 3
        else 0 end as gcs_score
    ,  case when heartrate_max is null then null
        when heartrate_max > 125 then 6
        when heartrate_min < 33 then 4
        when heartrate_max >= 107 and heartrate_max <= 125 then 3
        when heartrate_max >= 89 and heartrate_max <= 106 then 1
        else 0 end as heartrate_score
    ,  case when meanbp_min is null then null
        when meanbp_min < 20.65 then 4
        when meanbp_min < 51 then 3
        when meanbp_max > 143.44 then 3
        when meanbp_min >= 51 and meanbp_min < 61.33 then 2
        else 0 end as meanbp_score
    ,  case when resprate_min is null then null
        when resprate_min <   6 then 10
        when resprate_max >  44 then  9
        when resprate_max >  30 then  6
        when resprate_max >  22 then  1
        when resprate_min <  13 then 1 else 0
        end as resprate_score
    ,  case when tempc_max is null then null
        when tempc_max > 39.88 then 6
        when tempc_min >= 33.22 and tempc_min <= 35.93 then 4
        when tempc_max >= 33.22 and tempc_max <= 35.93 then 4
        when tempc_min < 33.22 then 3
        when tempc_min > 35.93 and tempc_min <= 36.39 then 2
        when tempc_max >= 36.89 and tempc_max <= 39.88 then 2
        else 0 end as temp_score
    ,  case 
        when SUM(urineoutput) OVER W is null then null
        when SUM(urineoutput) OVER W < 671.09 then 10
        when SUM(urineoutput) OVER W > 6896.80 then 8
        when SUM(urineoutput) OVER W >= 671.09
        and SUM(urineoutput) OVER W <= 1426.99 then 5
        when SUM(urineoutput) OVER W >= 1427.00
        and SUM(urineoutput) OVER W <= 2544.14 then 1
        else 0 end as UrineOutput_score
    ,  case when mechvent is null then null
        when mechvent = 1 then 9
        else 0 end as mechvent_score
    ,  case when ElectiveSurgery is null then null
        when ElectiveSurgery = 1 then 0
        else 6 end as electivesurgery_score
  from scorecomp
  WINDOW W as
  (
    PARTITION BY icustay_id
    ORDER BY hr
    ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING
  )
)
, score_final as
(
  select s.*
    -- Look for the worst instantaneous score over the last 24 hours
    -- Impute 0 if the score is missing
    , preiculos_score AS preiculos_score_24hours
    , electivesurgery_score as electivesurgery_score_24hours
    , coalesce(MAX(age_score) OVER W, 0)::SMALLINT as age_score_24hours
    , coalesce(MAX(gcs_score) OVER W, 0)::SMALLINT as gcs_score_24hours
    , coalesce(MAX(heartrate_score) OVER W, 0)::SMALLINT as heartrate_score_24hours
    , coalesce(MAX(meanbp_score) OVER W,0)::SMALLINT as meanbp_score_24hours
    , coalesce(MAX(resprate_score) OVER W,0)::SMALLINT as resprate_score_24hours
    , coalesce(MAX(temp_score) OVER W,0)::SMALLINT as temp_score_24hours
    , coalesce(MAX(UrineOutput_score) OVER W,0)::SMALLINT as UrineOutput_score_24hours
    , coalesce(MAX(mechvent_score) OVER W,0)::SMALLINT as mechvent_score_24hours

    -- sum together data for final OASIS
    , (preiculos_score
    + electivesurgery_score
    + coalesce(MAX(age_score) OVER W, 0)
    + coalesce(MAX(gcs_score) OVER W, 0)
    + coalesce(MAX(heartrate_score) OVER W, 0)
    + coalesce(MAX(meanbp_score) OVER W,0)
    + coalesce(MAX(resprate_score) OVER W,0)
    + coalesce(MAX(temp_score) OVER W,0)
    + coalesce(MAX(UrineOutput_score) OVER W,0)
    + coalesce(MAX(mechvent_score) OVER W,0)
    )::SMALLINT
    as OASIS_24hours
  from scorecalc s
  WINDOW W as
  (
    PARTITION BY icustay_id
    ORDER BY hr
    ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING
  )
)
select * from score_final
where hr >= 0
order by icustay_id, hr;
