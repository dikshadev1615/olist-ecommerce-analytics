
-- Q1. Which states have the highest late-delivery rates?
CREATE OR REPLACE VIEW state_late_delivery AS
SELECT c.customer_state,
		COUNT(*) AS delivered_orders,
		SUM(CASE WHEN o.Delivery_Status = 'Late' THEN 1 ELSE 0 END) AS late_orders,
		ROUND(100.0 * SUM(CASE WHEN o.Delivery_Status = 'Late' THEN 1 ELSE 0 END)/ COUNT(*),2)
		AS late_delivery_rate_pct
FROM orders o JOIN customers_staging c
ON o.customer_id = c.customer_id
WHERE o.Delivery_Status IN ('Early', 'Late')
GROUP BY c.customer_state;

SELECT * FROM state_late_delivery;

-- Q2. Which sellers have the biggest delivery-performance problems?

CREATE OR REPLACE VIEW seller_delivery_performance AS
SELECT oi.seller_id, s.seller_city, s.seller_state,
    COUNT(DISTINCT o.order_id) AS delivered_orders,
    COUNT(DISTINCT CASE WHEN o.Delivery_Status = 'Late' THEN o.order_id END) AS late_orders,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.Delivery_Status = 'Late' THEN o.order_id END) / COUNT(DISTINCT o.order_id),2) 
    AS late_delivery_rate_pct,
		ROUND( AVG(CASE WHEN o.Delivery_Status = 'Late'
				THEN o.Delivery_Delay_Days END),2 ) AS avg_late_delay_days
FROM order_items_staging oi
JOIN orders o ON oi.order_id = o.order_id
JOIN sellers_staging s ON oi.seller_id = s.seller_id
WHERE o.Delivery_Status IN ('Early', 'Late')
GROUP BY oi.seller_id, s.seller_city, s.seller_state
HAVING COUNT(DISTINCT o.order_id) >= 50
ORDER BY late_delivery_rate_pct DESC;

SELECT * FROM seller_delivery_performance;


-- Q3. Does seller-to-carrier handover time affect late delivery?
CREATE OR REPLACE VIEW handover_vs_late_delivery AS
SELECT
    CASE
        WHEN o.Carrier_Handover_Days <= 1 THEN '0-1 days'
        WHEN o.Carrier_Handover_Days <= 2 THEN '1-2 days'
        WHEN o.Carrier_Handover_Days <= 3 THEN '2-3 days'
        WHEN o.Carrier_Handover_Days <= 5 THEN '3-5 days'
        ELSE '>5 days'
    END AS handover_time_bucket,

    COUNT(*) AS delivered_orders,

    SUM( CASE WHEN o.Delivery_Status = 'Late' THEN 1 ELSE 0 END ) AS late_orders,
	ROUND( 100.0 * SUM( CASE WHEN o.Delivery_Status = 'Late' THEN 1 ELSE 0 END ) / COUNT(*),2) 
    AS late_delivery_rate_pct,
	ROUND(AVG(o.Carrier_Handover_Days), 2) AS avg_handover_days
FROM orders o
WHERE o.Delivery_Status IN ('Early', 'Late')
AND o.Carrier_Handover_Days IS NOT NULL
GROUP BY
    CASE
        WHEN o.Carrier_Handover_Days <= 1 THEN '0-1 days'
        WHEN o.Carrier_Handover_Days <= 2 THEN '1-2 days'
        WHEN o.Carrier_Handover_Days <= 3 THEN '2-3 days'
        WHEN o.Carrier_Handover_Days <= 5 THEN '3-5 days'
        ELSE '>5 days' END
HAVING COUNT(*) >= 50;

SELECT * FROM handover_vs_late_delivery;

-- Q4. How much revenue is associated with late deliveries?

CREATE OR REPLACE VIEW late_delivery_revenue AS
SELECT
    ROUND(SUM(oi.price), 2) AS total_delivered_revenue,
		ROUND(SUM(CASE
					WHEN o.Delivery_Status = 'Late'
					THEN oi.price
					ELSE 0 END), 2) AS late_delivery_revenue,

		ROUND( 100.0 * SUM(CASE
					WHEN o.Delivery_Status = 'Late'
					THEN oi.price
					ELSE 0 END ) / SUM(oi.price),2) AS late_revenue_pct,
		COUNT(DISTINCT CASE WHEN o.Delivery_Status = 'Late' THEN o.order_id END) AS late_orders

FROM orders o JOIN order_items_staging oi
ON o.order_id = oi.order_id
WHERE o.Delivery_Status IN ('Early', 'Late');

SELECT * FROM late_delivery_revenue;


-- Q5. Which high-value late categories/orders are the biggest priority?
CREATE OR REPLACE VIEW high_value_late_categories AS
WITH late_order_category AS (
SELECT o.order_id,  COALESCE(NULLIF(TRIM(REPLACE
							(REPLACE(ct.product_category_name_english,'\r',''),
							'\n','')),''),
					NULLIF(TRIM( REPLACE(REPLACE(p.product_category_name,'\r',''),
							'\n','')),''),'Unknown / Missing Category') AS category,

        ROUND(SUM(oi.price),2) AS order_value,
		ROUND(MAX(o.Delivery_Delay_Days),2) AS delay_days

    FROM orders o
	JOIN order_items_staging oi ON o.order_id = oi.order_id
	JOIN products_staging p ON oi.product_id = p.product_id
	LEFT JOIN category_translation_staging ct
	ON p.product_category_name = ct.product_category_name

    WHERE o.Delivery_Status = 'Late'
	GROUP BY o.order_id,
	COALESCE(NULLIF(TRIM(REPLACE(REPLACE(ct.product_category_name_english,'\r',''),
				'\n','')),''),
            NULLIF(TRIM(REPLACE(REPLACE(p.product_category_name,'\r',''),
				'\n','')),''),'Unknown / Missing Category')),

category_summary AS (
			SELECT category, COUNT(DISTINCT order_id) AS late_orders,
			ROUND(SUM(order_value),2) AS late_revenue,
			ROUND(SUM(order_value)/ NULLIF(COUNT(DISTINCT order_id), 0),2) AS avg_late_order_value,
			ROUND(MAX(order_value),2) AS highest_late_order_value
FROM late_order_category
GROUP BY category),

ranked_orders AS (
				SELECT category, order_id AS highest_value_late_order_id,
				order_value AS highest_value_order, delay_days AS highest_value_order_delay,
				ROW_NUMBER() OVER (PARTITION BY category ORDER BY order_value DESC, order_id) AS rn
FROM late_order_category)

SELECT cs.category, cs.late_orders, cs.late_revenue,
		ROUND(100.0 * cs.late_revenue/ NULLIF(SUM(cs.late_revenue) OVER (),0),2) 
        AS late_revenue_share_pct,
cs.avg_late_order_value, ro.highest_value_late_order_id, ro.highest_value_order, ro.highest_value_order_delay
FROM category_summary cs
JOIN ranked_orders ro
		ON cs.category = ro.category
		AND ro.rn = 1

ORDER BY cs.late_revenue DESC, cs.category;


SELECT * FROM high_value_late_categories;
    
-- Q6. Does product weight/volume relate to freight cost and delivery delay?
CREATE OR REPLACE VIEW product_size_logistics AS
WITH product_metrics AS (
						SELECT oi.order_id, oi.order_item_id, oi.price, oi.freight_value, p.product_weight_g,
						ROUND(p.product_length_cm * p.product_height_cm * p.product_width_cm,2) AS product_volume_cm3,
						o.delivery_days, o.Delivery_Delay_Days, o.Delivery_Status
FROM order_items_staging oi
JOIN products_staging p ON oi.product_id = p.product_id
JOIN orders o ON oi.order_id = o.order_id
WHERE p.product_weight_g IS NOT NULL),

weight_analysis AS (
					SELECT
					CASE
					WHEN product_weight_g <= 500 THEN '0-500g'
					WHEN product_weight_g <= 1000 THEN '501g-1kg'
					WHEN product_weight_g <= 3000 THEN '1-3kg'
					WHEN product_weight_g <= 5000 THEN '3-5kg'
					WHEN product_weight_g <= 10000 THEN '5-10kg'
					ELSE '>10kg' END AS metric,	
        COUNT(*) AS order_items,
        ROUND(AVG(product_weight_g), 2) AS avg_weight_g,
        ROUND(AVG(freight_value), 2) AS avg_freight,
        ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
        ROUND(100.0 * SUM(
                CASE WHEN Delivery_Status = 'Late' THEN 1 ELSE 0 END) / COUNT(*),2) AS late_delivery_rate_pct
    FROM product_metrics
    GROUP BY
        CASE
            WHEN product_weight_g <= 500 THEN '0-500g'
            WHEN product_weight_g <= 1000 THEN '501g-1kg'
            WHEN product_weight_g <= 3000 THEN '1-3kg'
            WHEN product_weight_g <= 5000 THEN '3-5kg'
            WHEN product_weight_g <= 10000 THEN '5-10kg'
            ELSE '>10kg'
        END),

volume_analysis AS (
				SELECT
					CASE
						WHEN product_volume_cm3 <= 1000 THEN '0-1K cm3'
						WHEN product_volume_cm3 <= 5000 THEN '1K-5K cm3'
						WHEN product_volume_cm3 <= 10000 THEN '5K-10K cm3'
						WHEN product_volume_cm3 <= 50000 THEN '10K-50K cm3'
						WHEN product_volume_cm3 <= 100000 THEN '50K-100K cm3'
						ELSE '>100K cm3'
					END AS metric,
        COUNT(*) AS order_items,
        ROUND(AVG(product_volume_cm3), 2) AS avg_volume_cm3,
        ROUND(AVG(freight_value), 2) AS avg_freight,
        ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
        ROUND(100.0 * SUM(
			CASE WHEN Delivery_Status = 'Late' THEN 1 ELSE 0 END) / COUNT(*),2) AS late_delivery_rate_pct
    FROM product_metrics
    WHERE product_volume_cm3 IS NOT NULL
    GROUP BY
        CASE
            WHEN product_volume_cm3 <= 1000 THEN '0-1K cm3'
            WHEN product_volume_cm3 <= 5000 THEN '1K-5K cm3'
            WHEN product_volume_cm3 <= 10000 THEN '5K-10K cm3'
            WHEN product_volume_cm3 <= 50000 THEN '10K-50K cm3'
            WHEN product_volume_cm3 <= 100000 THEN '50K-100K cm3'
            ELSE '>100K cm3'
        END)

SELECT
    'WEIGHT' AS analysis_type, metric, order_items,
    avg_weight_g AS avg_size,
    NULL AS avg_volume_cm3,
    avg_freight, avg_delivery_days, late_delivery_rate_pct
FROM weight_analysis

UNION ALL

SELECT
    'VOLUME' AS analysis_type, metric, order_items,
    NULL AS avg_size, avg_volume_cm3, avg_freight,
    avg_delivery_days, late_delivery_rate_pct
FROM volume_analysis

ORDER BY analysis_type, avg_size;
    
SELECT * FROM product_size_logistics;

-- Q7. Which product categories have the highest shipping burden?
CREATE OR REPLACE VIEW category_shipping_burden AS

SELECT
    COALESCE(NULLIF(TRIM(REPLACE(REPLACE(ct.product_category_name_english,'\r',''),
			'\n','')),''),
			NULLIF(TRIM(REPLACE(REPLACE(p.product_category_name,'\r',''),
			'\n','')),''),'Unknown / Missing Category') AS category,

    COUNT(*) AS order_items,
	ROUND(SUM(oi.price),2) AS product_revenue,
	ROUND(SUM(oi.freight_value),2) AS freight_cost,
	ROUND(100.0 * SUM(oi.freight_value)/ NULLIF(SUM(oi.price), 0),2) AS shipping_burden_pct,
	ROUND(AVG(oi.freight_value),2) AS avg_freight_per_item

FROM order_items_staging oi
JOIN products_staging p 
	ON oi.product_id = p.product_id
LEFT JOIN category_translation_staging ct
    ON p.product_category_name = ct.product_category_name

GROUP BY COALESCE(NULLIF(TRIM(REPLACE(REPLACE(ct.product_category_name_english,'\r',''),
					'\n','')),''),
					NULLIF(TRIM(REPLACE(REPLACE(p.product_category_name,'\r',''),
                    '\n','')),''),'Unknown / Missing Category')

HAVING COUNT(*) >= 100
ORDER BY shipping_burden_pct DESC;

SELECT * FROM category_shipping_burden;


-- Q8. Do repeat customers experience different delivery outcomes?
CREATE OR REPLACE  VIEW repeat_customer_delivery AS
WITH customer_order_sequence AS (
		SELECT o.order_id, c.customer_unique_id, o.Delivery_Status, 
			   o.delivery_days,o.Delivery_Delay_Days,
		ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY o.order_purchase_timestamp)
        AS order_sequence

    FROM orders o
    JOIN customers_staging c
	ON o.customer_id = c.customer_id
    WHERE o.Delivery_Status IN ('Early', 'Late'))

SELECT
    CASE
	WHEN order_sequence = 1 THEN 'New Customer' ELSE 'Repeat Customer'
    END AS customer_type,

    COUNT(*) AS delivered_orders,
	SUM( CASE WHEN Delivery_Status = 'Late' THEN 1 ELSE 0 END ) AS late_orders,
	ROUND(100.0 * SUM(CASE WHEN Delivery_Status = 'Late' THEN 1 ELSE 0 END) / COUNT(*),2)
    AS late_delivery_rate_pct,
	ROUND(AVG(delivery_days), 2) AS avg_delivery_days,
	ROUND(AVG(CASE
                WHEN Delivery_Status = 'Late'
                THEN Delivery_Delay_Days
				END),2) AS avg_late_delay_days

FROM customer_order_sequence

	GROUP BY CASE
			WHEN order_sequence = 1 THEN 'New Customer'
			ELSE 'Repeat Customer' END
ORDER BY late_delivery_rate_pct DESC;
    
    SELECT * FROM repeat_customer_delivery;
    
  
    -- Q9. What is the financial contribution of repeat customers?
CREATE OR REPLACE VIEW repeat_customer_financial_contribution AS
WITH customer_order_sequence AS (
    SELECT o.order_id, c.customer_unique_id,
	ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY o.order_purchase_timestamp) AS order_sequence
    FROM orders o
    JOIN customers_staging c
	ON o.customer_id = c.customer_id),

order_revenue AS 
				(SELECT oi.order_id,
				ROUND(SUM(oi.price), 2) AS order_revenue
				FROM order_items_staging oi
				GROUP BY oi.order_id),

customer_revenue AS 
	(SELECT CASE
			WHEN cos.order_sequence = 1 THEN 'New Customer'
			ELSE 'Repeat Customer'
			END AS customer_type,
			cos.order_id,
			orv.order_revenue
			FROM customer_order_sequence cos
			JOIN order_revenue orv
			ON cos.order_id = orv.order_id)

SELECT
    customer_type,
    COUNT(*) AS orders,
    ROUND(SUM(order_revenue), 2) AS total_revenue,
    ROUND(100.0 * SUM(order_revenue)/ SUM(SUM(order_revenue)) OVER (),2) AS revenue_contribution_pct,
    ROUND(AVG(order_revenue), 2) AS avg_order_value
FROM customer_revenue
GROUP BY customer_type
ORDER BY total_revenue DESC;

SELECT * FROM repeat_customer_financial_contribution;

-- Q10. Which categories are commercially strong and operationally healthy?
CREATE OR REPLACE VIEW category_commercial_operational_health AS

WITH category_items AS (
    SELECT oi.order_id, oi.product_id, oi.price, oi.freight_value,
			COALESCE(NULLIF(TRIM(REPLACE(
					REPLACE(ct.product_category_name_english, '\r', ''),'\n', '')),''),
					NULLIF(TRIM(REPLACE(REPLACE(p.product_category_name, '\r', ''),'\n', '')),''),
					'Unknown / Missing Category') AS category

FROM order_items_staging oi
JOIN products_staging p
	ON oi.product_id = p.product_id
LEFT JOIN category_translation_staging ct
	ON p.product_category_name = ct.product_category_name),

	order_category AS 
					(SELECT ci.order_id, ci.category,
					MAX(o.delivery_days) AS delivery_days,
                    MAX( CASE WHEN o.Delivery_Status = 'Late' THEN 1 ELSE 0 END) AS is_late

FROM category_items ci
JOIN orders o
        ON ci.order_id = o.order_id
WHERE o.Delivery_Status IN ('Early', 'Late')
GROUP BY ci.order_id, ci.category),

category_commercial AS (SELECT category,
						ROUND(SUM(price), 2) AS revenue,
						ROUND(100.0 * SUM(freight_value)/ NULLIF(SUM(price), 0),2) AS shipping_burden_pct
FROM category_items
GROUP BY category),

category_operational AS
						(SELECT category, COUNT(*) AS orders,
						ROUND(AVG(delivery_days),2) AS avg_delivery_days,
						SUM(is_late) AS late_orders,
						ROUND(100.0 * SUM(is_late)/ NULLIF(COUNT(*), 0),2) AS late_delivery_rate_pct

						FROM order_category
						GROUP BY category),

category_metrics AS 
						(SELECT co.category, co.orders, cc.revenue, co.late_orders,
						co.late_delivery_rate_pct, co.avg_delivery_days, cc.shipping_burden_pct
						FROM category_operational co
						JOIN category_commercial cc
						ON co.category = cc.category
						WHERE co.orders >= 100),

ranked_categories AS
						(SELECT *, NTILE(4) OVER ( ORDER BY revenue DESC, category) AS revenue_quartile,
						NTILE(4) OVER (ORDER BY late_delivery_rate_pct ASC, category) AS delivery_quartile
						FROM category_metrics)


SELECT category, orders, revenue, late_delivery_rate_pct, 
	   avg_delivery_days, shipping_burden_pct,

CASE
	WHEN revenue_quartile = 1 AND delivery_quartile = 1 THEN 'Strong & Healthy'
	WHEN revenue_quartile = 1 AND delivery_quartile IN (2, 3, 4) THEN 'Strong but Operationally Risky'
	WHEN revenue_quartile IN (2, 3, 4) AND delivery_quartile = 1 THEN 'Healthy but Lower Commercial Scale'
	ELSE 'Lower Scale & Higher Risk' 
    END AS category_position

FROM ranked_categories
ORDER BY
		CASE
        WHEN revenue_quartile = 1 AND delivery_quartile = 1 THEN 1
		WHEN revenue_quartile = 1 AND delivery_quartile IN (2, 3, 4) THEN 2
		WHEN revenue_quartile IN (2, 3, 4) AND delivery_quartile = 1 THEN 3
		ELSE 4 END,
revenue DESC,category;


SELECT * FROM category_commercial_operational_health;

    -- Q11. Which sellers are commercially important but operationally problematic?
CREATE OR REPLACE VIEW seller_commercial_operational_risk AS
WITH seller_metrics AS
					(SELECT oi.seller_id,
						TRIM(REPLACE(REPLACE(s.seller_city,'\r',''),'\n','')) AS seller_city,
						TRIM(REPLACE(REPLACE(s.seller_state,'\r',''),'\n','')) AS seller_state,
						COUNT(DISTINCT o.order_id) AS delivered_orders,
						COUNT(DISTINCT CASE WHEN o.Delivery_Status = 'Late' THEN o.order_id END) 
                        AS late_orders,
					ROUND(SUM(oi.price),2) AS revenue,
					ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.Delivery_Status = 'Late' THEN o.order_id END) 
                    / NULLIF( COUNT(DISTINCT o.order_id),0),2) AS late_delivery_rate_pct,
					ROUND(AVG(CASE WHEN o.Delivery_Status = 'Late'
							  THEN o.Delivery_Delay_Days END),2) AS avg_late_delay_days

					FROM order_items_staging oi
					JOIN orders o
							ON oi.order_id = o.order_id
					JOIN sellers_staging s
							ON oi.seller_id = s.seller_id
					WHERE o.Delivery_Status IN ('Early', 'Late')
					GROUP BY oi.seller_id,
								TRIM(REPLACE(REPLACE(s.seller_city, '\r',''),'\n','')),
								TRIM(REPLACE(REPLACE(s.seller_state,'\r',''),'\n',''))

					HAVING COUNT(DISTINCT o.order_id) >= 50),

ranked_sellers AS
				(SELECT seller_id, seller_city, seller_state, delivered_orders,
				late_orders, revenue, late_delivery_rate_pct, avg_late_delay_days,
				NTILE(4) OVER (ORDER BY revenue DESC, seller_id) AS revenue_quartile,
				NTILE(4) OVER (ORDER BY	late_delivery_rate_pct DESC, seller_id) AS risk_quartile
				FROM seller_metrics)


SELECT
		seller_id, seller_city, seller_state, delivered_orders, late_orders,
		revenue, late_delivery_rate_pct, avg_late_delay_days,
		CASE
		WHEN revenue_quartile = 1 AND risk_quartile = 1
        THEN 'High Commercial Value & High Operational Risk'
		WHEN revenue_quartile = 1 AND risk_quartile IN (2, 3)
        THEN 'High Commercial Value & Moderate Risk'
		END AS seller_priority

FROM ranked_sellers
WHERE revenue_quartile = 1 AND risk_quartile IN (1, 2, 3)
ORDER BY late_delivery_rate_pct DESC, revenue DESC, seller_id;


SELECT * FROM seller_commercial_operational_risk;

    
    -- Q12. Where should Olist intervene first?
CREATE OR REPLACE VIEW seller_intervention_priority AS
WITH seller_order_metrics AS 
						(SELECT	oi.seller_id, o.order_id,
						SUM(oi.price) AS order_revenue,
						CASE WHEN o.Delivery_Status = 'Late' THEN SUM(oi.price) ELSE 0
						END AS late_revenue,
						CASE WHEN o.Delivery_Status = 'Late' THEN 1 ELSE 0
						END AS late_order,
						CASE WHEN o.Delivery_Status = 'Late' THEN o.Delivery_Delay_Days ELSE NULL
						END AS late_delay_days
					
						FROM orders o JOIN order_items_staging oi
										ON o.order_id = oi.order_id
						WHERE o.Delivery_Status IN ('Early', 'Late')
						GROUP BY	oi.seller_id, o.order_id, o.Delivery_Status, o.Delivery_Delay_Days),

seller_metrics AS 
				(SELECT seller_id, COUNT(*) AS delivered_orders, SUM(late_order) AS late_orders,
				ROUND(SUM(order_revenue), 2) AS revenue, ROUND(SUM(late_revenue), 2) AS late_revenue,
				ROUND(100.0 * SUM(late_order) / COUNT(*),2) AS late_delivery_rate_pct,
				ROUND(AVG(late_delay_days),2) AS avg_late_delay_days

				FROM seller_order_metrics
				GROUP BY seller_id
				HAVING COUNT(*) >= 50),

ranked_sellers AS 
				(SELECT *, NTILE(4) OVER (ORDER BY late_revenue) AS commercial_quartile,
					NTILE(4) OVER ( ORDER BY late_delivery_rate_pct) AS risk_quartile,
					NTILE(4) OVER ( ORDER BY avg_late_delay_days ) AS severity_quartile
					FROM seller_metrics)


SELECT
    seller_id, delivered_orders, late_orders, revenue, 
    late_revenue, late_delivery_rate_pct, avg_late_delay_days,commercial_quartile,
    risk_quartile, severity_quartile,
	(commercial_quartile + risk_quartile + severity_quartile) AS intervention_score,

    CASE
        WHEN (commercial_quartile + risk_quartile + severity_quartile) >= 10
        THEN 'PRIORITY 1 - Immediate Intervention'
		WHEN (commercial_quartile + risk_quartile + severity_quartile) >= 7
        THEN 'PRIORITY 2 - Targeted Intervention'
		ELSE 'PRIORITY 3 - Monitor' END AS intervention_priority

FROM ranked_sellers
ORDER BY intervention_score DESC, late_revenue DESC;
    
SELECT * FROM seller_intervention_priority;
    
-- Q13. Which customer/category segments drove revenue growth?
-- Comparable period: Jan-Oct 2017 vs Jan-Oct 2018
CREATE OR REPLACE VIEW revenue_growth_segments AS
WITH customer_order_sequence AS 
							(SELECT o.order_id, c.customer_unique_id,
							ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY
							o.order_purchase_timestamp, o.order_id) AS order_sequence
						
							FROM orders o JOIN customers_staging c
							ON o.customer_id = c.customer_id),

customer_segment_revenue AS
						(SELECT CASE
								WHEN cos.order_sequence = 1 THEN 'New Customer' ELSE 'Repeat Customer' END AS segment,
								SUM( CASE
										WHEN o.order_purchase_timestamp >= '2017-01-01'
										 AND o.order_purchase_timestamp < '2017-11-01'
										THEN oi.price
										ELSE 0 END) AS revenue_2017,
								SUM(CASE
										WHEN o.order_purchase_timestamp >= '2018-01-01'
										 AND o.order_purchase_timestamp < '2018-11-01'
										THEN oi.price
										ELSE 0 END) AS revenue_2018
			
						FROM orders o JOIN order_items_staging oi
						ON o.order_id = oi.order_id
						JOIN customer_order_sequence cos
						ON o.order_id = cos.order_id
						WHERE o.order_status = 'delivered'
						GROUP BY	CASE	WHEN cos.order_sequence = 1 THEN 'New Customer' ELSE 'Repeat Customer' END),

category_revenue AS 
				(SELECT COALESCE(NULLIF(TRIM(REPLACE(REPLACE(ct.product_category_name_english,'\r',''),'\n','')),''),
						NULLIF(TRIM(REPLACE(REPLACE(p.product_category_name,'\r',''),'\n','')),''),
						'Unknown / Missing Category') AS category,
						SUM( CASE
								WHEN o.order_purchase_timestamp >= '2017-01-01'
								 AND o.order_purchase_timestamp < '2017-11-01'
								THEN oi.price
								ELSE 0 END) AS revenue_2017,
						SUM(CASE
								WHEN o.order_purchase_timestamp >= '2018-01-01'
								AND o.order_purchase_timestamp < '2018-11-01'
								THEN oi.price
								ELSE 0 END) AS revenue_2018
						
                        FROM orders o JOIN order_items_staging oi ON o.order_id = oi.order_id
									  JOIN products_staging p ON oi.product_id = p.product_id
                                      LEFT JOIN category_translation_staging ct
                                      ON p.product_category_name = ct.product_category_name
						
                        WHERE o.order_status = 'delivered'
						GROUP BY COALESCE( NULLIF(TRIM(REPLACE(REPLACE(ct.product_category_name_english,'\r',''),'\n','')),''),
										   NULLIF(TRIM(REPLACE(REPLACE(p.product_category_name,'\r',''),'\n','')),''),
										   'Unknown / Missing Category')),

combined AS 
	(SELECT 'CUSTOMER SEGMENT' AS analysis_type, segment AS segment_name, revenue_2017, revenue_2018
		FROM customer_segment_revenue
		UNION ALL
		SELECT 'PRODUCT CATEGORY' AS analysis_type, category AS segment_name, revenue_2017, revenue_2018
		FROM category_revenue),


growth AS 
		(SELECT analysis_type, segment_name, ROUND( revenue_2017, 2 ) AS revenue_2017,
			ROUND(revenue_2018,2) AS revenue_2018,
			ROUND(revenue_2018 - revenue_2017,2) AS revenue_growth
		FROM combined),


total_growth AS 
			(SELECT SUM(revenue_growth) AS total_revenue_growth 
				FROM growth
				WHERE analysis_type = 'PRODUCT CATEGORY'),


final_growth AS
			(SELECT g.analysis_type, g.segment_name, g.revenue_2017, g.revenue_2018, g.revenue_growth,
					ROUND( 100.0 * g.revenue_growth / NULLIF( g.revenue_2017,0),2) AS growth_pct,
					CASE
					WHEN g.analysis_type = 'PRODUCT CATEGORY' THEN 
					ROUND(100.0 * g.revenue_growth / NULLIF(t.total_revenue_growth,0),2)
					ELSE NULL
					END AS contribution_to_net_category_growth_pct
            FROM growth g
			CROSS JOIN total_growth t
			WHERE g.revenue_growth > 0)


SELECT analysis_type, segment_name, revenue_2017, revenue_2018, revenue_growth,
       growth_pct, contribution_to_net_category_growth_pct
FROM final_growth
ORDER BY analysis_type, revenue_growth DESC;


SELECT * FROM revenue_growth_segments;
    
    -- Q14. Are the biggest revenue categories also the best CX categories?
CREATE OR REPLACE VIEW category_revenue_vs_cx AS
WITH category_items AS
					(SELECT oi.order_id, oi.price,
							COALESCE(NULLIF(TRIM(REPLACE(REPLACE(ct.product_category_name_english,'\r',''),'\n','')),''),
									NULLIF(TRIM(REPLACE(REPLACE(p.product_category_name,'\r',''),'\n','')),''),
									'Unknown / Missing Category') AS category

					FROM order_items_staging oi
					JOIN products_staging p ON oi.product_id = p.product_id
					LEFT JOIN category_translation_staging ct ON p.product_category_name = ct.product_category_name),



category_revenue AS 
				(SELECT category, COUNT(DISTINCT order_id) AS orders,
						ROUND(SUM(price),2) AS revenue
				FROM category_items
				GROUP BY category),



order_category_delivery AS 
						(SELECT ci.order_id, ci.category,
							MAX(o.Delivery_Delay_Days) AS delivery_delay_days,
							MAX(CASE WHEN o.Delivery_Status = 'Late' THEN 1 ELSE 0 END ) AS is_late
						FROM category_items ci
						JOIN orders o ON ci.order_id = o.order_id
						WHERE o.Delivery_Status IN ('Early', 'Late')
						GROUP BY ci.order_id, ci.category),

category_delivery AS
				(SELECT category, COUNT(*) AS delivered_orders,
							ROUND( 100.0 * SUM(is_late)/ NULLIF(COUNT(*), 0),2) AS late_delivery_rate_pct
				FROM order_category_delivery
                GROUP BY category),



order_reviews AS 
					(SELECT	order_id, AVG(review_score) AS avg_review_score
					FROM reviews_staging
                    GROUP BY order_id),



order_category_cx AS 
						(SELECT DISTINCT ci.order_id, ci.category, r.avg_review_score
						FROM category_items ci
						JOIN orders o
							ON ci.order_id = o.order_id
						JOIN order_reviews r
							ON ci.order_id = r.order_id
						WHERE o.Delivery_Status IN ('Early', 'Late')),

category_cx AS 
					(SELECT category, ROUND( AVG(avg_review_score),2 ) AS avg_review_score
					FROM order_category_cx
					GROUP BY category),



category_metrics AS 
						(SELECT r.category, r.orders, r.revenue,
								d.late_delivery_rate_pct, c.avg_review_score
						FROM category_revenue r
						JOIN category_delivery d
							ON r.category = d.category
						JOIN category_cx c
							ON r.category = c.category
						WHERE d.delivered_orders >= 100),


ranked_categories AS 
						(SELECT category, orders, revenue, late_delivery_rate_pct, avg_review_score,
						NTILE(4) OVER ( ORDER BY revenue DESC, category ) AS revenue_quartile,
						NTILE(4) OVER ( ORDER BY late_delivery_rate_pct ASC, category) AS delivery_quartile,
						NTILE(4) OVER ( ORDER BY avg_review_score DESC, category ) AS review_quartile
						FROM category_metrics)



SELECT 
		category, orders,revenue, late_delivery_rate_pct, avg_review_score,
		revenue_quartile, delivery_quartile, review_quartile,

CASE
			WHEN revenue_quartile = 1	AND delivery_quartile IN (1, 2) AND review_quartile IN (1, 2)
				THEN 'High Revenue & Strong CX'
			WHEN revenue_quartile = 1 AND (delivery_quartile IN (3, 4) OR review_quartile IN (3, 4))
				THEN 'High Revenue but CX Risk'
			WHEN revenue_quartile IN (2, 3, 4) AND delivery_quartile IN (1, 2) AND review_quartile IN (1, 2)
				THEN 'Lower Revenue but Strong CX'
			ELSE 'Mixed Performance'
			END AS category_position

FROM ranked_categories
ORDER BY revenue DESC, category;


SELECT * FROM category_revenue_vs_cx;