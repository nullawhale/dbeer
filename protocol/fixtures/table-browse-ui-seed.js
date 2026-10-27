// Disposable MongoDB fixture used only by scripts/test-table-browse-ui.sh.
// SQL/CQL fixtures in TableBrowseUIIntegrationTests use the same eight rows.
const fixture = db.getSiblingDB("dbeer_browse_ui");
fixture.browse_ui_items.drop();
fixture.browse_ui_items.insertMany([
  {_id: NumberInt(1), tenant: NumberInt(1), rank: NumberInt(1), id: NumberInt(1), label: "alpha", nullable: null},
  {_id: NumberInt(2), tenant: NumberInt(1), rank: NumberInt(1), id: NumberInt(2), label: "beta", nullable: ""},
  {_id: NumberInt(3), tenant: NumberInt(1), rank: NumberInt(2), id: NumberInt(3), label: "alpha", nullable: "NULL"},
  {_id: NumberInt(4), tenant: NumberInt(1), rank: NumberInt(2), id: NumberInt(4), label: "beta", nullable: "v"},
  {_id: NumberInt(5), tenant: NumberInt(1), rank: NumberInt(3), id: NumberInt(5), label: "alpha", nullable: "v"},
  {_id: NumberInt(6), tenant: NumberInt(2), rank: NumberInt(1), id: NumberInt(6), label: "gamma", nullable: null},
  {_id: NumberInt(7), tenant: NumberInt(2), rank: NumberInt(2), id: NumberInt(7), label: "alpha", nullable: ""},
  {_id: NumberInt(8), tenant: NumberInt(2), rank: NumberInt(3), id: NumberInt(8), label: "beta", nullable: "NULL"}
]);
