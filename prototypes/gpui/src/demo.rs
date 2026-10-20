//! Deterministic, synthetic data for the UI prototype. No database is connected.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DemoTable {
    Customers,
    Orders,
    Products,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Column {
    pub name: String,
    pub data_type: String,
    pub width: f32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Cell {
    Null,
    Text(String),
    Number(String),
    Bool(bool),
    Binary(String),
}

impl Cell {
    pub fn display(&self) -> String {
        match self {
            Self::Null => "NULL".into(),
            Self::Text(value) | Self::Number(value) => value.clone(),
            Self::Binary(value) => format!("base64:{value}"),
            Self::Bool(value) => value.to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct QueryResult {
    pub columns: Vec<Column>,
    pub rows: Vec<Vec<Cell>>,
}

impl DemoTable {
    pub const ALL: [Self; 3] = [Self::Customers, Self::Orders, Self::Products];

    pub fn name(self) -> &'static str {
        match self {
            Self::Customers => "customers",
            Self::Orders => "orders",
            Self::Products => "products",
        }
    }

    pub fn query(self) -> String {
        format!(
            "SELECT *\nFROM public.{}\nORDER BY id\nLIMIT 200;",
            self.name()
        )
    }

    pub fn columns(self) -> Vec<Column> {
        let definitions: &[(&str, &str, f32)] = match self {
            Self::Customers => &[
                ("id", "int8", 72.0),
                ("name", "text", 230.0),
                ("email", "text", 260.0),
                ("city", "text", 150.0),
                ("active", "bool", 90.0),
                ("credit_limit", "numeric(12,2)", 150.0),
                ("note", "text", 240.0),
            ],
            Self::Orders => &[
                ("id", "int8", 82.0),
                ("customer_id", "int8", 120.0),
                ("ordered_at", "timestamp", 190.0),
                ("status", "text", 130.0),
                ("total", "numeric(12,2)", 140.0),
                ("paid", "bool", 90.0),
                ("note", "text", 260.0),
            ],
            Self::Products => &[
                ("id", "int8", 72.0),
                ("name", "text", 230.0),
                ("style", "text", 175.0),
                ("price", "numeric(10,2)", 110.0),
                ("stock", "int4", 100.0),
                ("abv", "numeric(4,1)", 100.0),
                ("note", "text", 260.0),
            ],
        };
        definitions
            .iter()
            .map(|&(name, data_type, width)| Column {
                name: name.into(),
                data_type: data_type.into(),
                width,
            })
            .collect()
    }

    pub fn rows(self) -> Vec<Vec<Cell>> {
        match self {
            Self::Customers => customers(),
            Self::Orders => orders(),
            Self::Products => products(),
        }
    }
}

/// Dispatch only known fixture queries. Edited SQL never reaches a database.
pub fn execute_fixture(sql: &str) -> Result<QueryResult, String> {
    let normalized = normalize(sql);
    for table in DemoTable::ALL {
        if normalized == normalize(&table.query()) {
            return Ok(QueryResult {
                columns: table.columns(),
                rows: table.rows(),
            });
        }
        let plain_count = format!("select count(*) from public.{}", table.name());
        let aliased_count = format!("select count(*) as count from public.{}", table.name());
        if normalized == plain_count || normalized == aliased_count {
            return Ok(QueryResult {
                columns: vec![Column {
                    name: "count".into(),
                    data_type: "int8".into(),
                    width: 120.0,
                }],
                rows: vec![vec![Cell::Number(table.rows().len().to_string())]],
            });
        }
    }
    Err("Demo query not supported. This prototype has no database connection. Use a table's generated SELECT query or SELECT COUNT(*) FROM public.<table>; to inspect its synthetic fixture.".into())
}

fn normalize(sql: &str) -> String {
    // Ignore formatting and one optional statement terminator, but preserve the
    // exact query shape. Additional clauses and statements remain unsupported.
    sql.trim()
        .strip_suffix(';')
        .unwrap_or(sql.trim())
        .split_whitespace()
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>()
        .join(" ")
}

fn text(value: impl Into<String>) -> Cell {
    Cell::Text(value.into())
}

fn number(value: impl ToString) -> Cell {
    Cell::Number(value.to_string())
}

fn example_note(index: usize) -> Cell {
    match index % 8 {
        0 => Cell::Null,
        1 => text(""),
        2 => text("NULL"),
        3 => text("Synthetic demo record"),
        4 => text("Priority sample"),
        5 => Cell::Null,
        6 => text("Review next batch"),
        _ => text("Fixture data only"),
    }
}

fn customers() -> Vec<Vec<Cell>> {
    const NAMES: [&str; 24] = [
        "Demo Alder Taproom",
        "Demo Amber Market",
        "Demo Birch Kitchen",
        "Demo Cedar Bottle Shop",
        "Demo Clover Cafe",
        "Demo Copper Tavern",
        "Demo Dune Store",
        "Demo Elm Pantry",
        "Demo Fern Bar",
        "Demo Flint Hall",
        "Demo Grove Market",
        "Demo Harbor Taproom",
        "Demo Hazel Kitchen",
        "Demo Iris Cafe",
        "Demo Juniper Store",
        "Demo Larch Tavern",
        "Demo Maple Pantry",
        "Demo Meadow Bar",
        "Demo Moss Bottle Shop",
        "Demo Oak Hall",
        "Demo Pine Market",
        "Demo Reed Cafe",
        "Demo Spruce Kitchen",
        "Demo Willow Taproom",
    ];
    const CITIES: [&str; 6] = [
        "Sample Harbor",
        "Demo Heights",
        "Example Bay",
        "Sample Valley",
        "Demo Ridge",
        "Example Grove",
    ];
    NAMES
        .iter()
        .enumerate()
        .map(|(index, name)| {
            vec![
                number(index + 1),
                text(*name),
                if index == 5 {
                    Cell::Null
                } else {
                    text(format!("store{:02}@example.test", index + 1))
                },
                text(CITIES[index % CITIES.len()]),
                Cell::Bool(index % 5 != 4),
                // Keep exact decimal strings rather than converting via float.
                number(format!("{}.{:02}", 1000 + index * 125, (index % 4) * 25)),
                example_note(index),
            ]
        })
        .collect()
}

fn orders() -> Vec<Vec<Cell>> {
    const STATUSES: [&str; 4] = ["completed", "processing", "shipped", "pending"];
    (0..32)
        .map(|index| {
            vec![
                number(1001 + index),
                number(index % 24 + 1),
                text(format!(
                    "2026-10-{:02} {:02}:30:00",
                    index % 18 + 1,
                    index % 8 + 9
                )),
                text(STATUSES[index % STATUSES.len()]),
                number(format!("{}.{:02}", 48 + index * 17, (index % 4) * 25)),
                Cell::Bool(index % 4 != 3),
                example_note(index),
            ]
        })
        .collect()
}

fn products() -> Vec<Vec<Cell>> {
    // Fictional product names; values are strings to preserve decimal precision.
    const PRODUCTS: [(&str, &str, &str, u32, &str); 24] = [
        ("Demo Golden Hour", "Helles Lager", "5.50", 144, "4.8"),
        ("Demo Pine Trail", "West Coast IPA", "7.25", 96, "6.5"),
        ("Demo Cloud Atlas", "Hazy IPA", "7.50", 72, "6.2"),
        ("Demo Copper Leaf", "Amber Ale", "6.00", 120, "5.2"),
        ("Demo Night Harbor", "Dry Stout", "6.50", 64, "4.5"),
        ("Demo Orchard Path", "Saison", "7.00", 48, "5.8"),
        ("Demo Summer Field", "Wheat Beer", "5.75", 160, "4.6"),
        ("Demo Red Lantern", "Red Ale", "6.25", 84, "5.4"),
        ("Demo Bright Water", "Pilsner", "5.50", 192, "4.7"),
        ("Demo Stone Bridge", "Porter", "6.75", 56, "5.9"),
        ("Demo Meadow Light", "Session IPA", "6.00", 128, "3.8"),
        ("Demo Forest Echo", "Double IPA", "8.50", 36, "8.2"),
        ("Demo Berry Drift", "Fruit Sour", "7.75", 60, "4.2"),
        ("Demo Frost Line", "Cold IPA", "7.25", 80, "6.0"),
        ("Demo Brown Pebble", "Brown Ale", "6.25", 92, "5.1"),
        ("Demo Velvet Sky", "Oatmeal Stout", "7.00", 40, "5.6"),
        ("Demo Maple Ridge", "Bock", "7.50", 32, "6.8"),
        ("Demo Citrus Loop", "Pale Ale", "6.50", 108, "5.0"),
        ("Demo Quiet Tide", "Alcohol Free", "4.50", 200, "0.0"),
        ("Demo Old Compass", "Belgian Tripel", "9.00", 24, "9.1"),
        ("Demo Silver Birch", "Kellerbier", "6.00", 76, "4.9"),
        ("Demo Apricot Moon", "Farmhouse Ale", "8.25", 44, "6.3"),
        ("Demo Ember Glow", "Rauchbier", "7.00", 28, "5.3"),
        ("Demo Final Harvest", "Barleywine", "12.50", 0, "11.0"),
    ];
    PRODUCTS
        .iter()
        .enumerate()
        .map(|(index, &(name, style, price, stock, abv))| {
            vec![
                number(index + 1),
                text(name),
                text(style),
                number(price),
                number(stock),
                number(abv),
                example_note(index),
            ]
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_queries_dispatch_to_their_exact_fixtures() {
        for table in DemoTable::ALL {
            let result = execute_fixture(&table.query()).unwrap();
            assert_eq!(result.columns, table.columns());
            assert_eq!(result.rows, table.rows());
            assert!((20..=40).contains(&result.rows.len()));
            assert!(
                result
                    .rows
                    .iter()
                    .all(|row| row.len() == result.columns.len())
            );
        }
    }

    #[test]
    fn query_formatting_and_ascii_case_are_ignored() {
        let result =
            execute_fixture("  select  *\nfrom\tPUBLIC.Products\nORDER by ID limit 200  ; \n")
                .unwrap();
        assert_eq!(result.rows, DemoTable::Products.rows());
        assert!(execute_fixture("SELECT * FROM public.orders ORDER BY id LIMIT 200").is_ok());
    }

    #[test]
    fn edited_queries_and_mutations_are_honestly_unsupported() {
        for sql in [
            "DELETE FROM public.customers;",
            "UPDATE public.products SET price = 0;",
            "SELECT * FROM public.products ORDER BY id LIMIT 2;",
            "SELECT * FROM public.products WHERE id = 1 ORDER BY id LIMIT 200;",
            "SELECT * FROM public.customers ORDER BY id LIMIT 200; DROP TABLE customers;",
            "SELECT * FROM public.customers ORDER BY id LIMIT 200;;",
            "SELECT 1;",
            "",
        ] {
            assert!(
                execute_fixture(sql)
                    .unwrap_err()
                    .contains("no database connection")
            );
        }
    }

    #[test]
    fn null_empty_text_and_literal_null_remain_distinct() {
        let rows = DemoTable::Products.rows();
        assert_eq!(rows[0][6], Cell::Null);
        assert_eq!(rows[1][6], Cell::Text(String::new()));
        assert_eq!(rows[2][6], Cell::Text("NULL".into()));
        assert_ne!(rows[0][6], rows[2][6]);
        assert_eq!(rows[0][3], Cell::Number("5.50".into()));
        assert_eq!(rows[18][5], Cell::Number("0.0".into()));
    }

    #[test]
    fn count_queries_report_fixture_row_count() {
        for table in DemoTable::ALL {
            for projection in ["COUNT(*)", "COUNT(*) AS count"] {
                let query = format!("SELECT {projection} FROM public.{};", table.name());
                let result = execute_fixture(&query).unwrap();
                assert_eq!(result.columns[0].name, "count");
                assert_eq!(result.rows, vec![vec![number(table.rows().len())]]);
            }
        }
    }
}
