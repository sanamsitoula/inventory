﻿-->-->-- src/Frapid.Web/Areas/MixERP.Inventory/db/PostgreSQL/2.1.update/src/01.types-domains-tables-and-constraints/tables-and-constraints.sql --<--<--
ALTER TABLE inventory.inventory_setup
ADD COLUMN IF NOT EXISTS validate_returns boolean NOT NULL DEFAULT(true);


-->-->-- src/Frapid.Web/Areas/MixERP.Inventory/db/PostgreSQL/2.1.update/src/02.functions-and-logic/inventory.get_cost_of_goods_sold.sql --<--<--
DROP FUNCTION IF EXISTS inventory.get_cost_of_goods_sold(_item_id integer, _unit_id integer, _store_id integer, _quantity numeric(30, 6));

CREATE FUNCTION inventory.get_cost_of_goods_sold(_item_id integer, _unit_id integer, _store_id integer, _quantity numeric(30, 6))
RETURNS numeric(30, 6)
AS
$$
    DECLARE _backup_quantity            numeric(30, 6);
    DECLARE _base_quantity              numeric(30, 6);
    DECLARE _base_unit_id               integer;
    DECLARE _base_unit_cost             numeric(30, 6);
    DECLARE _total_sold                 integer;
    DECLARE _office_id                  integer = inventory.get_office_id_by_store_id(_store_id);
    DECLARE _method                     national character varying(1000) = inventory.get_cost_of_good_method(_office_id);
BEGIN
	IF(_quantity = 0) THEN
		RETURN 0;
	END IF;


    --backup base quantity in numeric(30, 6)
    _backup_quantity                    := inventory.get_base_quantity_by_unit_id(_unit_id, _quantity);
    --convert base quantity to whole number
    _base_quantity                      := CEILING(_backup_quantity);
    _base_unit_id                       := inventory.get_root_unit_id(_unit_id);
        
    IF(_method = 'MAVCO') THEN
        RETURN inventory.get_mavcogs(_item_id, _store_id, _base_quantity, 1.00);
    END IF;

	--GET THE SUM TOTAL QUANTITIES SOLD IN THIS STORE
    SELECT COALESCE(SUM(base_quantity), 0)
    INTO _total_sold
    FROM inventory.verified_checkout_details_view
    WHERE transaction_type='Cr'
    AND item_id = _item_id
	AND store_id = _store_id;

	IF(_method = 'FIFO') THEN
		WITH all_purchases
		AS
		(
			SELECT ROW_NUMBER() OVER(ORDER BY value_date, checkout_detail_id) AS id, *
			FROM inventory.verified_checkout_details_view
			WHERE item_id = _item_id
			AND store_id = _store_id
			AND transaction_type = 'Dr'
		), purchase_prices
		AS
		(
			SELECT
				(
					SELECT SUM(base_quantity)
					FROM all_purchases AS i
					WHERE  i.id <= v.id
				) AS total,
				*
			FROM all_purchases AS v
		)
		SELECT
            (purchase_prices.price * purchase_prices.quantity) / purchase_prices.base_quantity
        INTO
            _base_unit_cost
		FROM purchase_prices
		WHERE total > _total_sold
		ORDER BY total
		LIMIT 1;

		_base_unit_cost := _base_unit_cost * _base_quantity;		
	END IF;

	IF(_method = 'LIFO') THEN
		WITH all_purchases
		AS
		(
			SELECT ROW_NUMBER() OVER(ORDER BY value_date, checkout_detail_id) AS id, *
			FROM inventory.verified_checkout_details_view
			WHERE item_id = _item_id
			AND store_id = _store_id
			AND transaction_type = 'Dr'
		), purchase_prices
		AS
		(
			SELECT
				(
					SELECT SUM(base_quantity)
					FROM all_purchases AS i
					WHERE  i.id >= v.id
				) AS total,
				*
			FROM all_purchases AS v
		)
		SELECT
			(purchase_prices.price * purchase_prices.quantity) / purchase_prices.base_quantity
		INTO
            _base_unit_cost
		FROM purchase_prices
		WHERE total > _total_sold
		ORDER BY total
		LIMIT 1;

		_base_unit_cost := _base_unit_cost * _base_quantity;		
	END IF;

	IF(_base_unit_cost IS NULL) THEN
		_base_unit_cost := inventory.get_item_cost_price(_item_id, _base_unit_id) * _base_quantity;
	END IF;

    --APPLY numeric(30, 6) QUANTITY PROVISON
    _base_unit_cost := _base_unit_cost * (_backup_quantity / _base_quantity);


    RETURN _base_unit_cost;
END
$$
LANGUAGE plpgsql;


--SELECT inventory.get_cost_of_goods_sold(1, 1, 1, 1);




-->-->-- src/Frapid.Web/Areas/MixERP.Inventory/db/PostgreSQL/2.1.update/src/02.functions-and-logic/inventory.get_total_customer_due.sql --<--<--
DROP FUNCTION IF EXISTS inventory.get_total_customer_due(office_id integer, customer_id integer);

CREATE FUNCTION inventory.get_total_customer_due(office_id integer, customer_id integer)
RETURNS DECIMAL(24, 4)
AS
$$
    DECLARE _account_id                     integer         = inventory.get_account_id_by_customer_id($2);
    DECLARE _debit                          numeric(30, 6)  = 0;
    DECLARE _credit                         numeric(30, 6)  = 0;
    DECLARE _local_currency_code            national character varying(12) = core.get_currency_code_by_office_id($1); 
    DECLARE _base_currency_code             national character varying(12) = inventory.get_currency_code_by_customer_id($2);
    DECLARE _amount_in_local_currency       numeric(30, 6)= 0;
    DECLARE _amount_in_base_currency        numeric(30, 6)= 0;
    DECLARE _er decimal_strict2 = 0;
BEGIN

    SELECT SUM(amount_in_local_currency)
    INTO _debit
    FROM finance.verified_transaction_view
    WHERE finance.verified_transaction_view.account_id IN (SELECT * FROM finance.get_account_ids(_account_id))
    AND finance.verified_transaction_view.office_id IN (SELECT * FROM core.get_office_ids($1))
    AND tran_type='Dr';

    SELECT SUM(amount_in_local_currency)
    INTO _credit
    FROM finance.verified_transaction_view
    WHERE finance.verified_transaction_view.account_id IN (SELECT * FROM finance.get_account_ids(_account_id))
    AND finance.verified_transaction_view.office_id IN (SELECT * FROM core.get_office_ids($1))
    AND tran_type='Cr';

    _er := COALESCE(finance.convert_exchange_rate($1, _local_currency_code, _base_currency_code), 0);


    IF(_er = 0) THEN
        RAISE INFO 'Exchange rate between % and % was not found.', _local_currency_code, _base_currency_code
        USING ERRCODE='P4010';
    END IF;


    _amount_in_local_currency = COALESCE(_debit, 0) - COALESCE(_credit, 0);


    _amount_in_base_currency = _amount_in_local_currency * _er; 

    RETURN _amount_in_base_currency;
END
$$
LANGUAGE plpgsql;



-->-->-- src/Frapid.Web/Areas/MixERP.Inventory/db/PostgreSQL/2.1.update/src/02.functions-and-logic/inventory.get_total_supplier_due.sql --<--<--
DROP FUNCTION IF EXISTS inventory.get_total_supplier_due(office_id integer, supplier_id integer);

CREATE FUNCTION inventory.get_total_supplier_due(office_id integer, supplier_id integer)
RETURNS DECIMAL(24, 4)
AS
$$
    DECLARE _account_id                     integer         = inventory.get_account_id_by_supplier_id($2);
    DECLARE _debit                          numeric(30, 6)  = 0;
    DECLARE _credit                         numeric(30, 6)  = 0;
    DECLARE _local_currency_code            national character varying(12) = core.get_currency_code_by_office_id($1); 
    DECLARE _base_currency_code             national character varying(12) = inventory.get_currency_code_by_customer_id($2);
    DECLARE _amount_in_local_currency       numeric(30, 6)= 0;
    DECLARE _amount_in_base_currency        numeric(30, 6)= 0;
    DECLARE _er decimal_strict2 = 0;
BEGIN

    SELECT SUM(amount_in_local_currency)
    INTO _debit
    FROM finance.verified_transaction_view
    WHERE finance.verified_transaction_view.account_id IN (SELECT * FROM finance.get_account_ids(_account_id))
    AND finance.verified_transaction_view.office_id IN (SELECT * FROM core.get_office_ids($1))
    AND tran_type='Dr';

    SELECT SUM(amount_in_local_currency)
    INTO _credit
    FROM finance.verified_transaction_view
    WHERE finance.verified_transaction_view.account_id IN (SELECT * FROM finance.get_account_ids(_account_id))
    AND finance.verified_transaction_view.office_id IN (SELECT * FROM core.get_office_ids($1))
    AND tran_type='Cr';

    _er := COALESCE(finance.convert_exchange_rate($1, _local_currency_code, _base_currency_code), 0);


    IF(_er = 0) THEN
        RAISE INFO 'Exchange rate between % and % was not found.', _local_currency_code, _base_currency_code
        USING ERRCODE='P4010';
    END IF;


    _amount_in_local_currency = COALESCE(_credit, 0) - COALESCE(_debit, 0);


    _amount_in_base_currency = _amount_in_local_currency * _er; 

    RETURN _amount_in_base_currency;
END
$$
LANGUAGE plpgsql;


-->-->-- src/Frapid.Web/Areas/MixERP.Inventory/db/PostgreSQL/2.1.update/src/03.menus/menus.sql --<--<--
SELECT * FROM core.create_menu('MixERP.Inventory', 'InventorySetup', 'Inventory Setup', '/dashboard/inventory/setup/is', 'content', 'Setup');


SELECT * FROM auth.create_app_menu_policy
(
    'Admin', 
    core.get_office_id_by_office_name('Default'), 
    'MixERP.Inventory',
    '{*}'::text[]
);



-->-->-- src/Frapid.Web/Areas/MixERP.Inventory/db/PostgreSQL/2.1.update/src/99.ownership.sql --<--<--
DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'frapid_db_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT * FROM pg_tables 
    WHERE NOT schemaname = ANY(ARRAY['pg_catalog', 'information_schema'])
    AND tableowner <> 'frapid_db_user'
    LOOP
        EXECUTE 'ALTER TABLE '|| this.schemaname || '.' || this.tablename ||' OWNER TO frapid_db_user;';
    END LOOP;
END
$$
LANGUAGE plpgsql;

DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'frapid_db_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT oid::regclass::text as mat_view
    FROM   pg_class
    WHERE  relkind = 'm'
    LOOP
        EXECUTE 'ALTER TABLE '|| this.mat_view ||' OWNER TO frapid_db_user;';
    END LOOP;
END
$$
LANGUAGE plpgsql;

DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'frapid_db_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT 'ALTER '
        || CASE WHEN p.proisagg THEN 'AGGREGATE ' ELSE 'FUNCTION ' END
        || quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '(' 
        || pg_catalog.pg_get_function_identity_arguments(p.oid) || ') OWNER TO frapid_db_user;' AS sql
    FROM   pg_catalog.pg_proc p
    JOIN   pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE  NOT n.nspname = ANY(ARRAY['pg_catalog', 'information_schema'])
    LOOP        
        EXECUTE this.sql;
    END LOOP;
END
$$
LANGUAGE plpgsql;


DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'frapid_db_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT * FROM pg_views
    WHERE NOT schemaname = ANY(ARRAY['pg_catalog', 'information_schema'])
    AND viewowner <> 'frapid_db_user'
    LOOP
        EXECUTE 'ALTER VIEW '|| this.schemaname || '.' || this.viewname ||' OWNER TO frapid_db_user;';
    END LOOP;
END
$$
LANGUAGE plpgsql;


DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'frapid_db_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT 'ALTER SCHEMA ' || nspname || ' OWNER TO frapid_db_user;' AS sql FROM pg_namespace
    WHERE nspname NOT LIKE 'pg_%'
    AND nspname <> 'information_schema'
    LOOP
        EXECUTE this.sql;
    END LOOP;
END
$$
LANGUAGE plpgsql;



DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'frapid_db_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT      'ALTER TYPE ' || n.nspname || '.' || t.typname || ' OWNER TO frapid_db_user;' AS sql
    FROM        pg_type t 
    LEFT JOIN   pg_catalog.pg_namespace n ON n.oid = t.typnamespace 
    WHERE       (t.typrelid = 0 OR (SELECT c.relkind = 'c' FROM pg_catalog.pg_class c WHERE c.oid = t.typrelid)) 
    AND         NOT EXISTS(SELECT 1 FROM pg_catalog.pg_type el WHERE el.oid = t.typelem AND el.typarray = t.oid)
    AND         typtype NOT IN ('b')
    AND         n.nspname NOT IN ('pg_catalog', 'information_schema')
    LOOP
        EXECUTE this.sql;
    END LOOP;
END
$$
LANGUAGE plpgsql;


DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'report_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT * FROM pg_tables 
    WHERE NOT schemaname = ANY(ARRAY['pg_catalog', 'information_schema'])
    AND tableowner <> 'report_user'
    LOOP
        EXECUTE 'GRANT SELECT ON TABLE '|| this.schemaname || '.' || this.tablename ||' TO report_user;';
    END LOOP;
END
$$
LANGUAGE plpgsql;

DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'report_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT oid::regclass::text as mat_view
    FROM   pg_class
    WHERE  relkind = 'm'
    LOOP
        EXECUTE 'GRANT SELECT ON TABLE '|| this.mat_view  ||' TO report_user;';
    END LOOP;
END
$$
LANGUAGE plpgsql;

DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'report_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT 'GRANT EXECUTE ON '
        || CASE WHEN p.proisagg THEN 'AGGREGATE ' ELSE 'FUNCTION ' END
        || quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '(' 
        || pg_catalog.pg_get_function_identity_arguments(p.oid) || ') TO report_user;' AS sql
    FROM   pg_catalog.pg_proc p
    JOIN   pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE  NOT n.nspname = ANY(ARRAY['pg_catalog', 'information_schema'])
    LOOP        
        EXECUTE this.sql;
    END LOOP;
END
$$
LANGUAGE plpgsql;


DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'report_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT * FROM pg_views
    WHERE NOT schemaname = ANY(ARRAY['pg_catalog', 'information_schema'])
    AND viewowner <> 'report_user'
    LOOP
        EXECUTE 'GRANT SELECT ON '|| this.schemaname || '.' || this.viewname ||' TO report_user;';
    END LOOP;
END
$$
LANGUAGE plpgsql;


DO
$$
    DECLARE this record;
BEGIN
    IF(CURRENT_USER = 'report_user') THEN
        RETURN;
    END IF;

    FOR this IN 
    SELECT 'GRANT USAGE ON SCHEMA ' || nspname || ' TO report_user;' AS sql FROM pg_namespace
    WHERE nspname NOT LIKE 'pg_%'
    AND nspname <> 'information_schema'
    LOOP
        EXECUTE this.sql;
    END LOOP;
END
$$
LANGUAGE plpgsql;


