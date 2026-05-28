-- CROWDFUNDING ADVANCED ANALYSIS
-- ====================================================================================================================================================================================

CREATE DATABASE crowdfunding_db;
USE crowdfunding_db;
USE crowdfunding_db;
SELECT COUNT(*) FROM projects; 
SELECT COUNT(*) FROM crowdfunding_location; 

USE crowdfunding_db;
SET SQL_SAFE_UPDATES = 0;
-- Add proper datetime columns
ALTER TABLE projects
ADD COLUMN created_date     DATETIME NULL,
ADD COLUMN deadline_date    DATETIME NULL,
ADD COLUMN state_changed_date DATETIME NULL,
ADD COLUMN launched_date    DATETIME NULL;

--  Convert unix timestamps to datetime
UPDATE projects
SET
    created_date      = FROM_UNIXTIME(created_at),
    deadline_date     = FROM_UNIXTIME(deadline),
    state_changed_date = FROM_UNIXTIME(state_changed_at),
    launched_date     = FROM_UNIXTIME(launched_at);
-- ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 1: DATA QUALITY CHECK

-- 1a. Null audit across critical columns
SELECT
    COUNT(*)  AS total_projects,
    SUM(CASE WHEN name IS NULL THEN 1 ELSE 0 END) AS null_name,
    SUM(CASE WHEN goal IS NULL THEN 1 ELSE 0 END)  AS null_goal,
    SUM(CASE WHEN pledged IS NULL THEN 1 ELSE 0 END) AS null_pledged,
    SUM(CASE WHEN state IS NULL THEN 1 ELSE 0 END) AS null_state,
    SUM(CASE WHEN backers_count IS NULL THEN 1 ELSE 0 END) AS null_backers,
    ROUND(SUM(CASE WHEN goal IS NULL THEN 1 ELSE 0 END)* 100.0 / COUNT(*), 2) AS pct_null_goal
FROM projects;

-- 1b. Detect impossible records
SELECT id, name, goal, pledged,
    ROUND(pledged / NULLIF(goal, 0), 2) AS funding_ratio
FROM projects
WHERE pledged > goal * 10
ORDER BY funding_ratio DESC
LIMIT 20;

-- 1c. Campaign duration outliers
SELECT id, name,
    DATEDIFF(deadline_date, created_date) AS campaign_days
FROM projects
WHERE DATEDIFF(deadline_date, created_date) < 1
   OR DATEDIFF(deadline_date, created_date) > 365;

-- --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- SECTION 2: KPI SUMMARY — ONE QUERY, ALL KEY NUMBERS

SELECT
    COUNT(*) AS total_projects,
    COUNT(DISTINCT category_id) AS total_categories,
    COUNT(DISTINCT location_id)  AS total_locations,
    ROUND(SUM(goal * static_usd_rate), 2) AS total_goal_usd,
    ROUND(SUM(pledged * static_usd_rate), 2)  AS total_pledged_usd,
    ROUND(SUM(pledged * static_usd_rate) /
          NULLIF(SUM(goal * static_usd_rate), 0) * 100, 2) AS overall_funding_pct,
    SUM(backers_count) AS total_backers,
    ROUND(AVG(backers_count), 1) AS avg_backers_per_project,
    ROUND(AVG(DATEDIFF(deadline_date, created_date)), 1) AS avg_campaign_days
FROM projects;


-- --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 3: OUTCOME ANALYSIS WITH WINDOW FUNCTIONS

-- 3a. Projects by outcome with % share (Window Function)
SELECT state,
    COUNT(*) AS total_projects,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS pct_of_total,
    ROUND(SUM(pledged * static_usd_rate), 2) AS total_pledged_usd,
    ROUND(AVG(pledged * static_usd_rate), 2) AS avg_pledged_usd,
    ROUND(AVG(backers_count), 1) AS avg_backers
FROM projects
GROUP BY state
ORDER BY total_projects DESC;

-- 3b. Successful vs Failed — profile comparison using UNION ALL
SELECT
    'Successful Project Profile' AS profile,
    ROUND(AVG(goal * static_usd_rate), 2) AS avg_goal_usd,
    ROUND(AVG(pledged * static_usd_rate), 2) AS avg_raised_usd,
    ROUND(AVG(backers_count), 0) AS avg_backers,
    ROUND(AVG(DATEDIFF(deadline_date, created_date)), 0) AS avg_campaign_days,
    ROUND(AVG(pledged / NULLIF(goal,0) * 100), 1) AS avg_funded_pct
FROM projects
WHERE state = 'successful'

UNION ALL

SELECT
    'Failed Project Profile',
    ROUND(AVG(goal * static_usd_rate), 2),
    ROUND(AVG(pledged * static_usd_rate), 2),
    ROUND(AVG(backers_count), 0),
    ROUND(AVG(DATEDIFF(deadline_date, created_date)), 0),
    ROUND(AVG(pledged / NULLIF(goal,0) * 100), 1)
FROM projects
WHERE state = 'failed';


-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 4: TIME SERIES ANALYSIS

-- 4a. Monthly launches + MoM growth using LAG window function
WITH monthly_launches AS (
    SELECT
        DATE_FORMAT(created_date, '%Y-%m') AS yr_month,
        COUNT(*) AS total_launched,
        SUM(CASE WHEN state='successful' THEN 1 ELSE 0 END) AS successful
    FROM projects
    GROUP BY DATE_FORMAT(created_date, '%Y-%m')
)
SELECT
    yr_month,
    total_launched,
    successful,
    ROUND(successful * 100.0 / total_launched, 1) AS success_rate_pct,
    LAG(total_launched) OVER (ORDER BY yr_month) AS prev_month,
    ROUND(
        (total_launched - LAG(total_launched) OVER (ORDER BY yr_month))
        * 100.0 /
        NULLIF(LAG(total_launched) OVER (ORDER BY yr_month), 0)
    , 1) AS mom_growth_pct,
    SUM(total_launched) OVER (ORDER BY yr_month
        ROWS UNBOUNDED PRECEDING) AS cumulative_launches
FROM monthly_launches
ORDER BY yr_month;

-- 4b. Best quarter per year using RANK window function
WITH quarterly AS (
    SELECT
        YEAR(created_date) AS yr,
        CONCAT('Q', QUARTER(created_date)) AS qtr,
        COUNT(*) AS total,
        SUM(CASE WHEN state='successful'
                 THEN 1 ELSE 0 END) AS successful
    FROM projects
    GROUP BY yr, qtr
)
SELECT
    yr,
    qtr,
    total,
    successful,
    ROUND(successful * 100.0 / total, 2) AS success_rate_pct,
    RANK() OVER (PARTITION BY yr ORDER BY successful * 100.0 / total DESC) AS rank_in_year
FROM quarterly
ORDER BY yr, rank_in_year;

-- 4c. Weekend vs Weekday launches
-- Do projects launched on weekends perform differently?
SELECT
    CASE WHEN DAYOFWEEK(created_date) IN (1,7)
         THEN 'Weekend' ELSE 'Weekday'
    END AS launch_type,
    COUNT(*) AS total_projects,
    ROUND(AVG(backers_count), 1) AS avg_backers,
    ROUND(SUM(CASE WHEN state='successful' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS success_rate_pct
FROM projects
GROUP BY launch_type;


-- -----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 5: CATEGORY DEEP DIVE

-- 5a. Full category performance dashboard with RANK
SELECT
    cat.name AS category,
    COUNT(*) AS total_projects,
    ROUND(SUM(p.pledged * p.static_usd_rate), 2) AS total_raised_usd,
    ROUND(AVG(p.backers_count), 1)  AS avg_backers,
    ROUND(SUM(CASE WHEN p.state='successful' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2) AS success_rate_pct,
    RANK() OVER (ORDER BY
        SUM(CASE WHEN p.state='successful' THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*) DESC)  AS success_rank
FROM projects p
JOIN crowdfunding_category cat ON p.category_id = cat.id
GROUP BY cat.name
ORDER BY success_rate_pct DESC;
 
-- 5b. Category success trend YoY
-- Has any category improved over the years?
WITH cat_yearly AS (
    SELECT
        cat.name AS category,
        YEAR(p.created_date) AS yr,
        COUNT(*) AS total,
        SUM(CASE WHEN p.state='successful' THEN 1 ELSE 0 END) AS successful
    FROM projects p
    JOIN crowdfunding_category cat ON p.category_id = cat.id
    GROUP BY cat.name, yr
)
SELECT
    category,
    yr,
    ROUND(successful * 100.0 / total, 2) AS success_rate_pct,
    LAG(ROUND(successful * 100.0 / total, 2))
        OVER (PARTITION BY category ORDER BY yr) AS prev_year_rate,
    ROUND(
        ROUND(successful * 100.0 / total, 2) -
        LAG(ROUND(successful * 100.0 / total, 2))
            OVER (PARTITION BY category ORDER BY yr), 2) AS yoy_change_pts
FROM cat_yearly
ORDER BY category, yr;


-- ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 6: GOAL RANGE & DURATION ANALYSIS

-- 6a. Success rate by goal range (USD)
SELECT
    CASE
        WHEN goal * static_usd_rate < 1000    THEN '< $1K'
        WHEN goal * static_usd_rate < 5000    THEN '$1K – $5K'
        WHEN goal * static_usd_rate < 10000   THEN '$5K – $10K'
        WHEN goal * static_usd_rate < 50000   THEN '$10K – $50K'
        WHEN goal * static_usd_rate < 100000  THEN '$50K – $100K'
        ELSE '> $100K'
    END AS goal_bucket,
    COUNT(*) AS total_projects,
    SUM(CASE WHEN state='successful' THEN 1 ELSE 0 END) AS successful,
    ROUND(SUM(CASE WHEN state='successful' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2) AS success_rate_pct,
    ROUND(AVG(backers_count), 1) AS avg_backers
FROM projects
GROUP BY goal_bucket
ORDER BY MIN(goal * static_usd_rate);

-- 6b. Success rate by campaign duration
SELECT
    CASE
        WHEN DATEDIFF(deadline_date, created_date) <= 7   THEN '1–7 days'
        WHEN DATEDIFF(deadline_date, created_date) <= 14  THEN '8–14 days'
        WHEN DATEDIFF(deadline_date, created_date) <= 30  THEN '15–30 days'
        WHEN DATEDIFF(deadline_date, created_date) <= 60  THEN '31–60 days'
        ELSE '60+ days'
    END  AS duration_bucket,
    COUNT(*) AS total_projects,
    ROUND(SUM(CASE WHEN state='successful' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2) AS success_rate_pct,
    ROUND(AVG(backers_count), 1) AS avg_backers
FROM projects
WHERE DATEDIFF(deadline_date, created_date) BETWEEN 1 AND 180
GROUP BY duration_bucket
ORDER BY MIN(DATEDIFF(deadline_date, created_date));

-- 6c. SWEET SPOT FINDER
-- What goal range + duration combination gives highest success rate?
-- (Most useful insight for someone planning a campaign)
SELECT
    CASE
        WHEN goal * static_usd_rate < 5000   THEN '< $5K'
        WHEN goal * static_usd_rate < 20000  THEN '$5K – $20K'
        ELSE '> $20K'
    END AS goal_bucket,
    CASE
        WHEN DATEDIFF(deadline_date, created_date) <= 20  THEN '≤ 20 days'
        WHEN DATEDIFF(deadline_date, created_date) <= 40  THEN '21–40 days'
        ELSE '> 40 days'
    END AS duration_bucket,
    COUNT(*) AS total,
    ROUND(SUM(CASE WHEN state='successful' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 1) AS success_rate_pct
FROM projects
WHERE DATEDIFF(deadline_date, created_date) BETWEEN 1 AND 90
GROUP BY goal_bucket, duration_bucket
HAVING COUNT(*) >= 50
ORDER BY success_rate_pct DESC;

-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 7: TOP PROJECTS ANALYSIS

-- 7a. Top 10 by backers with rank and category context
SELECT
    p.name,
    cat.name AS category,
    p.backers_count,
    ROUND(p.pledged * p.static_usd_rate, 2) AS pledged_usd,
    ROUND(p.goal * p.static_usd_rate, 2) AS goal_usd,
    ROUND(p.pledged / NULLIF(p.goal,0) * 100, 1) AS funded_pct,
    DATEDIFF(p.deadline_date, p.created_date) AS campaign_days,
    RANK() OVER (ORDER BY p.backers_count DESC) AS backer_rank
FROM projects p
JOIN crowdfunding_category cat ON p.category_id = cat.id
WHERE p.state = 'successful'
ORDER BY backer_rank
LIMIT 10;

-- 7b. Top 10 by amount raised with overfunding insight
SELECT
    p.name,
    cat.name AS category,
    ROUND(p.pledged * p.static_usd_rate, 2) AS pledged_usd,
    ROUND(p.goal * p.static_usd_rate, 2)  AS goal_usd,
    ROUND((p.pledged - p.goal) * p.static_usd_rate, 2) AS overfunded_by_usd,
    ROUND(p.pledged / NULLIF(p.goal,0) * 100, 1) AS funded_pct,
    RANK() OVER (ORDER BY p.pledged * p.static_usd_rate DESC) AS revenue_rank
FROM projects p
JOIN crowdfunding_category cat ON p.category_id = cat.id
WHERE p.state = 'successful'
ORDER BY revenue_rank
LIMIT 10;


-- -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 8: ADVANCED WINDOW FUNCTION QUERIES


-- 8a. Each project ranked within its category by amount raised
-- Shows which projects are outliers in their own category
SELECT
    p.name,
    cat.name AS category,
    ROUND(p.pledged * p.static_usd_rate, 2) AS pledged_usd,
    ROUND(AVG(p.pledged * p.static_usd_rate)
          OVER (PARTITION BY cat.name), 2) AS category_avg_usd,
    ROUND(p.pledged * p.static_usd_rate -
          AVG(p.pledged * p.static_usd_rate)
              OVER (PARTITION BY cat.name), 2) AS vs_category_avg,
    RANK() OVER (PARTITION BY cat.name
                 ORDER BY p.pledged * p.static_usd_rate DESC) AS rank_in_category,
    ROUND(PERCENT_RANK() OVER (PARTITION BY cat.name
          ORDER BY p.pledged * p.static_usd_rate) * 100, 1) AS percentile_in_category
FROM projects p
JOIN crowdfunding_category cat ON p.category_id = cat.id
WHERE p.state = 'successful'
ORDER BY cat.name, rank_in_category;

-- 8b. Running total of funds raised month by month
SELECT
    DATE_FORMAT(created_date, '%Y-%m') AS yr_month,
    ROUND(SUM(pledged * static_usd_rate), 2) AS monthly_raised_usd,
    ROUND(SUM(SUM(pledged * static_usd_rate))
          OVER (ORDER BY DATE_FORMAT(created_date,'%Y-%m')
          ROWS UNBOUNDED PRECEDING), 2)  AS cumulative_raised_usd
FROM projects
WHERE state = 'successful'
GROUP BY DATE_FORMAT(created_date, '%Y-%m')
ORDER BY yr_month;

-- 8c. Backer tier analysis
-- Do projects with more backers succeed faster?
SELECT
    CASE
        WHEN backers_count < 100    THEN 'Micro  (< 100)'
        WHEN backers_count < 500    THEN 'Small  (100–499)'
        WHEN backers_count < 2000   THEN 'Mid    (500–1999)'
        WHEN backers_count < 10000  THEN 'Large  (2K–9999)'
        ELSE                             'Mega   (10K+)'
    END AS backer_tier,
    COUNT(*) AS projects,
    ROUND(AVG(DATEDIFF(state_changed_at, created_date)), 1) AS avg_days_to_success,
    ROUND(AVG(pledged * static_usd_rate), 2) AS avg_raised_usd,
    ROUND(AVG(pledged / NULLIF(goal,0) * 100), 1) AS avg_funded_pct
FROM projects
WHERE state = 'successful'
  AND state_changed_at IS NOT NULL
GROUP BY backer_tier
ORDER BY MIN(backers_count);


-- -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- SECTION 9: LOCATION ANALYSIS

-- Top 15 locations by projects + success rate
SELECT
    loc.displayable_name AS location,
    COUNT(*) AS total_projects,
    SUM(CASE WHEN p.state='successful' THEN 1 ELSE 0 END) AS successful,
    ROUND(SUM(CASE WHEN p.state='successful' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2) AS success_rate_pct,
    ROUND(AVG(p.backers_count), 1) AS avg_backers,
    ROUND(SUM(p.pledged * p.static_usd_rate), 2) AS total_raised_usd,
    RANK() OVER (ORDER BY COUNT(*) DESC) AS volume_rank
FROM projects p
JOIN crowdfunding_location loc ON p.location_id = loc.id
GROUP BY loc.displayable_name
ORDER BY total_projects DESC
LIMIT 15;