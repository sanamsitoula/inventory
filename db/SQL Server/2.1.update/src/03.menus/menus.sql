EXECUTE core.create_menu 'MixERP.Inventory', 'InventorySetup','Inventory Setup', '/dashboard/inventory/setup/is', 'child', 'Setup';

DECLARE @office_id integer = core.get_office_id_by_office_name('Default');
EXECUTE auth.create_app_menu_policy
'Admin', 
@office_id, 
'MixERP.Inventory',
'{*}';


GO
