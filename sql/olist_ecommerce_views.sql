USE olist_ecommerce;


-- Q1. Which states have the highest late-delivery rates?
SELECT * FROM state_late_delivery;

-- Q2. Which sellers have the biggest delivery-performance problems?
SELECT * FROM seller_delivery_performance;

-- Q3. Does seller-to-carrier handover time affect late delivery?
SELECT * FROM handover_vs_late_delivery;

-- Q4. How much revenue is associated with late deliveries?
SELECT * FROM late_delivery_revenue;

-- Q5. Which high-value late categories/orders are the biggest priority?
SELECT * FROM high_value_late_categories;

-- Q6. Does product weight/volume relate to freight cost and delivery delay?
SELECT * FROM product_size_logistics;

-- Q7. Which product categories have the highest shipping burden?
SELECT * FROM category_shipping_burden;

-- Q8. Do repeat customers experience different delivery outcomes?
SELECT * FROM repeat_customer_delivery;

-- Q9. What is the financial contribution of repeat customers?
SELECT * FROM repeat_customer_financial_contribution;

-- Q10. Which categories are commercially strong and operationally healthy?
SELECT * FROM category_commercial_operational_health;

-- Q11. Which sellers are commercially important but operationally problematic?
SELECT * FROM seller_commercial_operational_risk;

-- Q12. Where should Olist intervene first?
SELECT * FROM seller_intervention_priority;

-- Q13. Which customer/category segments drove revenue growth?
SELECT * FROM revenue_growth_segments;

-- Q14. Are the biggest revenue categories also the best CX categories?
SELECT * FROM category_revenue_vs_cx;