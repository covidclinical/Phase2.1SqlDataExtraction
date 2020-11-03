--##############################################################################
--### 4CE Phase 2.1
--### Date: September 25, 2020
--### Database: Oracle
--### Data Model: i2b2
--### Created By: Griffin Weber (weber@hms.harvard.edu)
--### Converted to Oracle By: Jaspreet Khanna (jaspreet.khanna@childrens.harvard.edu)
--##############################################################################
--*** THIS IS A DRAFT. 4CE SITES ARE NOT BEING ASKED TO RUN THIS SCRIPT YET. ***
--!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--!!! Run the 4CE Phase 1.1 script before you run this script.
--!!! Set all the obfuscation values in the Phase 1.1 #config table to 0.
--!!! This script uses the tables created by your 4CE Phase 1.1 script.
--!!! This is Oracle version of 4CE Phase 2.0 mssql script
--!!! This script has SQL blocks and based on settings in covid_config and config2 
--!!! tables selectively they have to be executed.
--!!! Changed PatientClinicalCourse SQL.
--!!! Changed days_since_admission 
--!!! Added siteid to all the files extracted
--!!! Fix for the wrong death_date (showing up as a future date) has not been applied in this release
--!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--------------------------------------------------------------------------------
-- General settings
--------------------------------------------------------------------------------
create table config2 (
	replace_patient_num number(1), -- Replace the patient_num with a unique random number
	save_as_columns number(1), -- Save the data as tables with separate columns per field
	save_as_prefix varchar2(50), -- Table name prefix when saving the data as tables
	output_as_columns number(1), -- Return the data in tables with separate columns per field
	output_as_csv number(1) -- Return the data in tables with a single column containing comma separated values
);


insert into config2
	select 
		1, -- replace_patient_num
		0, -- save_as_columns
		'P2', -- save_as_prefix (don't use "4CE" since it starts with a number)
		0, -- output_as_columns
		1 from dual; -- output_as_csv


--******************************************************************************
--******************************************************************************
--*** Create the Phase 2.0 patient level data tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Patient Summary: Dates, Outcomes, and Demographics
--------------------------------------------------------------------------------


create table PatientSummary (
	siteid varchar2(50) not null,
	patient_num varchar2(100) not null,
	admission_date date not null,
	days_since_admission integer not null,
	last_discharge_date date not null,
	still_in_hospital integer not null,
	severe_date date not null,
	severe integer not null,
	death_date date not null,
	deceased integer not null,
	sex varchar2(50) not null,
	age_group varchar2(50) not null,
	race varchar2(50) not null,
	race_collected integer not null
);

alter table PatientSummary add primary key (patient_num);

-- Truncate table PatientSummary ;

insert INTO patientsummary (
        siteid,
        patient_num,
        admission_date,
        days_since_admission,
        last_discharge_date,
        still_in_hospital,
        severe_date,
        severe,
        death_date,
        deceased,
        sex,
        age_group,
        race,
        race_collected
    )
	select '@', c.patient_num, c.admission_date, 
		round(sysdate - c.admission_date) ,
		(case when trunc(a.last_discharge_date) = trunc(sysdate)  then TO_DATE('01/01/1900','mm/dd/rrrr') 
          else a.last_discharge_date end),
		(case when trunc(a.last_discharge_date) = trunc(sysdate) then 1 else 0 end),
		nvl (c.severe_date,TO_DATE('01/01/1900','mm/dd/rrrr')  ),
		c.severe, 
		nvl(c.death_date,TO_DATE('01/01/1900','mm/dd/rrrr') ),
		(case when c.death_date is not null then 1 else 0 end),
		nvl(d.sex,'other'),
		nvl(d.age_group,'other'),
		(case when x.include_race=0 then 'other' else nvl(d.race,'other') end),
		x.include_race
	from covid_config x
		cross join covid_cohort c
		inner join (
			select patient_num, max(discharge_date) last_discharge_date
			from covid_admissions
			group by patient_num
		) a on c.patient_num=a.patient_num
		left outer join (
			select patient_num,
				max(sex) sex,
				max(age_group) age_group,
				max(race) race
			from covid_demographics_temp
			group by patient_num
		) d on c.patient_num=d.patient_num ;
        
        commit;

--------------------------------------------------------------------------------
-- Patient Clinical Course: Status by Number of Days Since Admission
--------------------------------------------------------------------------------

create table PatientClinicalCourse (
	siteid varchar2(50) not null,
	patient_num varchar2(100)  not null,
	days_since_admission integer  not null,
	calendar_date date not null,
	in_hospital integer  not null,
	severe integer  not null,
	deceased integer  not null
);
--select * from PatientClinicalCourse ;
alter table PatientClinicalCourse add primary key (patient_num, days_since_admission);

--  truncate table PatientClinicalCourse  ;

insert into PatientClinicalCourse (siteid, patient_num, days_since_admission, calendar_date, in_hospital, severe, deceased)
select siteid,patient_num,days_since_admission, calendar_date,
case when in_hospital is not null then 1 else 0 end in_hospital,
severe,
case when death_date is not null then 1 else 0 end DECEASED
 from
	(select '@' siteid, days_since_admission, patient_num,
		count(*) in_hospital,
		sum(severe) severe,
        max(admission_date) admission_date,
        max(death_date) death_date,
        max(d) calendar_date
	from (
		select distinct trunc(d.d)-trunc(c.admission_date) days_since_admission, d.d,c.admission_date,death_date,
			c.patient_num, severe
		from covid_date_list_temp d
			inner join covid_admissions p
				on trunc(p.admission_date)<=trunc(d.d) and trunc(p.discharge_date)>=trunc(d.d)
			inner join covid_cohort c
				on p.patient_num=c.patient_num and trunc(p.admission_date)>=trunc(c.admission_date)
	) t
	group by days_since_admission,patient_num
) ;
commit;


--------------------------------------------------------------------------------
-- Patient Observations: Selected Data Facts
--------------------------------------------------------------------------------

create table PatientObservations (
	siteid varchar2(50) not null,
	patient_num  varchar2(100)   not null,
	days_since_admission integer  not null,
	concept_type varchar2(50) not null,
	concept_code varchar2(50) not null,
	value numeric(18,5) not null
);

alter table PatientObservations add primary key (patient_num, concept_type, concept_code, days_since_admission);

-- truncate table PatientObservations ;

-- Diagnoses (3 character ICD9 codes) since 365 days before COVID
insert into PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select distinct '@',
		p.patient_num,
        trunc(f.start_date) - trunc(p.admission_date) days_since_admission,
		'DIAG-ICD9',
        substr(substr(f.concept_cd, length(code_prefix_icd9cm)+1, 999), 1, 3) icd_code_3chars ,
		-999
 	from covid_config x
		cross join observation_fact f
		inner join covid_cohort p 
        on f.patient_num=p.patient_num 
        and f.start_date >= (p.admission_date -365)
    where concept_cd like code_prefix_icd9cm||'%' and  code_prefix_icd9cm is not null;
    commit;
    
-- Diagnoses (3 character ICD10 codes) since 365 days before COVID
insert into PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select distinct '@',
		p.patient_num,
        trunc(f.start_date) - trunc(p.admission_date) days_since_admission,
		'DIAG-ICD10',
        substr(substr(f.concept_cd, length(code_prefix_icd10cm)+1, 999), 1, 3) icd_code_3chars,
		-999
 	from covid_config x
		cross join observation_fact f
		inner join covid_cohort p 
			on f.patient_num=p.patient_num 
                and f.start_date >= (p.admission_date -365)
    where concept_cd like code_prefix_icd10cm||'%' ; --and code_prefix_icd10cm is not null;
    
    commit;
 -- Medications (Med Class) since 365 days before COVID   
 insert into PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select distinct '@',
		p.patient_num,
         trunc(f.start_date) - trunc(p.admission_date) days_since_admission,
		'MED-CLASS',
		m.med_class,	
		-999
	from observation_fact f
		inner join covid_cohort p 
			on f.patient_num=p.patient_num 
                and f.start_date >= ( p.admission_date -365)
		inner join covid_med_map m
			on f.concept_cd = m.local_med_code;
 commit;
 
 -- Labs (LOINC) since 60 days (two months) before COVID
insert into PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select '@', 
		f.patient_num,
        trunc(f.start_date) - trunc(p.admission_date) days_since_admission,
		'LAB-LOINC',		
		l.loinc,
		avg(f.nval_num*l.scale_factor)
	from observation_fact f
		inner join covid_cohort p 
			on f.patient_num=p.patient_num
		inner join COVID_LAB_MAP l
			on f.concept_cd=l.local_lab_code
	where l.local_lab_code is not null
		and f.nval_num is not null
		and f.nval_num >= 0
        and f.start_date >= ( p.admission_date -60)
        and l.scale_factor is not null
    group by f.patient_num, trunc(f.start_date) - trunc(p.admission_date) , l.loinc;
 commit;   
-- Procedures (ICD9) each day since COVID (only procedures used in 4CE Phase 1.1 to determine severity)
insert into PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select distinct '@', 
		p.patient_num,
        trunc(f.start_date) - trunc(p.admission_date) days_since_admission,        
		'PROC-ICD9',
        substr(f.concept_cd, length(code_prefix_icd9proc)+1, 999),
		-999
 	from covid_config x
		cross join observation_fact f
		inner join covid_cohort p 
			on f.patient_num=p.patient_num 
				and f.start_date >= p.admission_date
    where concept_cd like code_prefix_icd9proc||'%' and code_prefix_icd9proc is not null
		and (
			-- Insertion of endotracheal tube
			f.concept_cd = x.code_prefix_icd9proc||'96.04'
			-- Invasive mechanical ventilation
            or regexp_like(f.concept_cd , x.code_prefix_icd9proc||'96.7[012]{1}') --Converted to ORACLE Regex 
		);
commit;
-- Procedures (ICD10) each day since COVID (only procedures used in 4CE Phase 1.1 to determine severity)

insert into PatientObservations (siteid, patient_num, days_since_admission, concept_type, concept_code, value)
	select distinct '@', p.patient_num,
        trunc(f.start_date) - trunc(p.admission_date) days_since_admission,
		'PROC-ICD10',
        substr(f.concept_cd, length(code_prefix_icd10pcs)+1, 999) ,
		-999
 	from covid_config x
		cross join observation_fact f
		inner join covid_cohort p 
			on f.patient_num=p.patient_num 
				and f.start_date >= p.admission_date
	where concept_cd like code_prefix_icd10pcs||'%'  and code_prefix_icd10pcs is not null
		and (
			-- Insertion of endotracheal tube
			f.concept_cd = x.code_prefix_icd10pcs||'0BH17EZ'
			-- Invasive mechanical ventilation
            or regexp_like(f.concept_cd , x.code_prefix_icd10pcs||'5A09[345]{1}[A-Z0-9]?') --Converted to ORACLE Regex 
		) ;
commit;


--******************************************************************************
--******************************************************************************
--*** Finalize Tables
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- Replace the patient_num with a random study_num integer
--------------------------------------------------------------------------------

create table PatientMapping (
	siteid varchar2(50) not null,
	patient_num varchar2(50)  not null,
	study_num varchar2(50)  not null
);

alter table PatientMapping add primary key (patient_num, study_num);

-- truncate table PatientMapping ;

set serveroutput on
declare

v_counts   integer := 0;
begin

 select count(*) into v_counts from config2 where replace_patient_num = 1;
 If v_counts > 0 Then
        insert into PatientMapping (siteid, patient_num, study_num)
        select distinct '@',m.patient_ide,m.patient_num
        from patient_mapping m
        inner join PatientSummary p
        on m.patient_ide = p.patient_num;

    	update PatientSummary t 
		set t.patient_num = ( select m.study_num 
                              from PatientMapping m 
                              where t.patient_num = m.patient_num)
        where exists ( select 'x' from PatientSummary m2
                              where t.patient_num = m2.patient_num  );
        
       	update PatientClinicalCourse t 
		set t.patient_num = ( select m.study_num 
                              from PatientMapping m 
                              where t.patient_num = m.patient_num)
        where exists ( select 'x' from PatientClinicalCourse m2
                              where t.patient_num = m2.patient_num  );   
            
        update PatientObservations t 
		set t.patient_num = ( select m.study_num 
                              from PatientMapping m 
                              where t.patient_num = m.patient_num)
        where exists ( select 'x' from PatientObservations m2
                              where t.patient_num = m2.patient_num  ); 
                              commit;
                        
                            
else

	insert into PatientMapping (siteid, patient_num, study_num)
		select '@', patient_num, patient_num
		from PatientSummary ;
                    commit;
 
 End if;

end;

--------------------------------------------------------------------------------
-- Set the siteid to a unique value for your institution.
--------------------------------------------------------------------------------
update PatientSummary set siteid = (select siteid from covid_config);
update PatientClinicalCourse set siteid = (select siteid from covid_config);
update PatientObservations set siteid = (select siteid from covid_config);
update PatientMapping set siteid = (select siteid from covid_config);
commit;

--******************************************************************************
--******************************************************************************
--*** Finish up
--******************************************************************************
--******************************************************************************

--------------------------------------------------------------------------------
-- OPTION #: Save the data as tables.
-- * Make sure everything looks reasonable.
-- * Export the tables to csv files.
--------------------------------------------------------------------------------
----To create a copy of the table with prefix run this SQL block
set serveroutput on

declare
v_save_as_prefix  varchar2(20) := ' ';
v_counts  INTEGER := 0;
v_sql  varchar2(4000);
begin
select save_as_prefix into v_save_as_prefix 
from config2 where save_as_columns = 1;

for r_data in ( select table_name from user_tables where table_name in
('COVID_DAILY_COUNTS','COVID_CLINICAL_COURSE','COVID_DEMOGRAPHICS','COVID_LABS','COVID_DIAGNOSES','COVID_MEDICATIONS','PATIENTMAPPING',
'PATIENTSUMMARY','PATIENTCLINICALCOURSE','PATIENTOBSERVATIONS') ) loop


        If v_save_as_prefix <> ' ' then
            select count(*) into v_counts 
            from user_tables
            where table_name = v_save_as_prefix||r_data.table_name ;

            If v_counts > 0 Then
              v_sql := 'Drop table '||v_save_as_prefix||r_data.table_name;
              execute immediate v_sql ;

            End If;
            
            v_sql := 'Create table '||v_save_as_prefix||r_data.table_name|| ' as select * from '||r_data.table_name ;
            execute immediate v_sql ;

        End If;

        end loop;
Exception
When no_data_found then
dbms_output.put_line( 'Per config setting skipping the run');

end;

----

--------------------------------------------------------------------------------
-- OPTION #: View the data as tables.
-- * Make sure everything looks reasonable.
-- * Copy into Excel, convert dates into YYYY-MM-DD format, save in csv format.
--------------------------------------------------------------------------------
--if exists (select * from config2 where output_as_columns = 1 )
--begin

	select * from PatientSummary order by admission_date, patient_num;
	select * from PatientClinicalCourse order by patient_num, days_since_admission;
	select * from PatientObservations order by patient_num, concept_type, concept_code, days_since_admission;
	select * from PatientMapping order by patient_num;
--end;

--------------------------------------------------------------------------------
-- OPTION #: View the data as csv strings.
-- * Copy and paste to a text file, save it FileName.csv.
-- * Make sure it is not saved as FileName.csv.txt.
--------------------------------------------------------------------------------
--To generate data extract files, run listed SQLs

--    File #1: PatientSummary.csv
--spool 'LocalPatientSummary.csv' ;
	select s PatientSummaryCSV
		from (
			select 0 i, 'siteid,patient_num,admission_date,days_since_admission,last_discharge_date,still_in_hospital,'
				||'severe_date,severe,death_date,deceased,sex,age_group,race,race_collected' S FROM DUAL
			union all 	
            select row_number() over (order by admission_date, patient_num) i,
				siteid
                ||','||cast(patient_num as varchar2(50))
                ||','||to_char(admission_date,'YYYY-MM-DD')  --YYYY-MM-DD
                ||','||to_char(days_since_admission)              
                ||','||to_char(last_discharge_date,'YYYY-MM-DD')  --YYYY-MM-DD
                ||','||to_char(still_in_hospital)    
                ||','||to_char(severe_date,'YYYY-MM-DD')  --YYYY-MM-DD
                ||','||to_char(severe)  
                ||','||to_char(death_date,'YYYY-MM-DD')  --YYYY-MM-DD
                ||','||to_char(deceased) 
                ||','||to_char(sex) 
                ||','||to_char(age_group) 
                ||','||to_char(race) 
                ||','||to_char(race_collected) 
			from PatientSummary
			union all select 9999999, '' FROM DUAL
            
            --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i;
--spool off;


--    File #2: PatientClinicalCourse.csv
--spool 'LocalPatientClinicalCourse.csv' ;
	select s PatientClinicalCourseCSV
		from (
			select 0 i, 'siteid,patient_num,days_since_admission,calendar_date,in_hospital,severe,deceased' s FROM DUAL
			union all 
			select row_number() over (order by patient_num, days_since_admission) i,
				siteid
                ||','||cast(patient_num as varchar2(50))
                ||','||to_char(days_since_admission) 
                ||','||to_char(calendar_date,'YYYY-MM-DD')  --YYYY-MM-DD
                ||','||to_char(in_hospital)
                ||','||to_char(severe)
                ||','||to_char(deceased)
			from PatientClinicalCourse
			union all select 9999999, '' FROM DUAL --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i ;
--spool off;
--    File #3: PatientObservations.csv

--spool  LocalPatientObservations.csv
	select s PatientObservationsCSV
		from (
			select 0 i, 'siteid,patient_num,days_since_admission,concept_type,concept_code,value' s FROM DUAL
			union all 
			select row_number() over (order by patient_num, concept_type, concept_code, days_since_admission) i,
            siteid
                ||','||cast(patient_num as varchar2(50))
                ||','||to_char(days_since_admission) 
                ||','||to_char(concept_type)
                ||','||to_char(concept_code)
                ||','||to_char(value)
			from PatientObservations
			union all select 9999999, '' FROM DUAL --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i;

--spool off;

--    File #4: PatientMapping.csv
--spool LocalPatientMapping.csv;
	select s PatientMappingCSV
		from (
			select 0 i, 'siteid,patient_num,study_num' s FROM DUAL
			union all 
			select row_number() over (order by patient_num) i,
             siteid
                ||','||to_char(patient_num)
                ||','||to_char(study_num)
			from PatientMapping
			union all select 9999999, '' FROM DUAL --Add a blank row to make sure the last line in the file with data ends with a line feed.
		) t
		order by i;
--spool off;   
