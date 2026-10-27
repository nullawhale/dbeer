// Disposable MongoDB 8.0 fixture used only by scripts/test-mongodb-ui.sh.
const fixture = db.getSiblingDB("dbeer_mongodb_ui");
const documents = [];
for (let i = 0; i < 450; i++) {
  documents.push({
    _id: ObjectId(i.toString(16).padStart(24, "0")),
    index: NumberInt(i),
    name: "Document " + i,
    category: i % 2 === 0 ? "active" : "draft",
    exactLong: NumberLong("9007199254740993"),
    amount: NumberDecimal("123456789.1234567890123456789"),
    createdAt: ISODate("2026-10-24T00:00:00.123Z"),
    binary: BinData(128, "AAEC/w=="),
    uuid: UUID("00112233-4455-6677-8899-aabbccddeeff"),
    timestamp: Timestamp({t: 4294967295, i: 7}),
    nullable: null,
    empty: "",
    literalNull: "NULL",
    enabled: true,
    nested: {name: "Nested value", values: [NumberInt(1), NumberLong("9007199254740993"), null, "", {}, []]},
    minimum: MinKey(),
    maximum: MaxKey()
  });
}
fixture.orders.insertMany(documents);
fixture.createView("active_orders", "orders", [{$match: {category: "active"}}]);
