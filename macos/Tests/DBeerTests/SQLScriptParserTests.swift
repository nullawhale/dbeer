import Foundation
import Testing
@testable import DBeer

struct SQLScriptParserTests {
    @Test func postgresProceduresDollarQuotesNestedCommentsAndEscapedValuesStayWhole() {
        let sql = #"""
        /* outer ; /* nested ; */ still comment */
        CREATE FUNCTION public.example() RETURNS text LANGUAGE plpgsql AS $body$
        BEGIN
          RETURN 'one;two' || $inner$three;four$inner$;
        END;
        $body$;
        SELECT E'escaped\';quote', 'doubled'';quote', "a"";identifier";
        """#
        let parsed = SQLScriptParser.parse(sql, engine: .postgresql)
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.statements.count == 2)
        #expect(parsed.statements[0].sql.contains("END;"))
        #expect(parsed.statements[0].sql.hasSuffix("$body$"))
        #expect(parsed.statements[1].sql.hasPrefix("SELECT E"))
        #expect(parsed.tokens.contains { $0.kind == .comment })
        for statement in parsed.statements {
            #expect((sql as NSString).substring(with: statement.range) == statement.sql)
        }
    }

    @Test func mysqlDelimiterProceduresTriggersAndQuotedDelimitersSplitIntoServerCommands() {
        let sql = #"""
        DELIMITER $$
        CREATE PROCEDURE example()
        BEGIN
          SELECT 'a; $$ b', "a\";$$value", `a``;identifier`;
          SELECT 2;
        END$$
        DELIMITER //
        CREATE TRIGGER example_trigger BEFORE INSERT ON example_table FOR EACH ROW
        BEGIN
          SET NEW.value = 'contains // and ;';
        END//
        DELIMITER ;
        CALL example();
        """#
        let parsed = SQLScriptParser.parse(sql, engine: .mysql)
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.statements.count == 3)
        #expect(parsed.statements[0].sql.hasPrefix("CREATE PROCEDURE"))
        #expect(parsed.statements[0].sql.hasSuffix("END"))
        #expect(parsed.statements[1].sql.hasPrefix("CREATE TRIGGER"))
        #expect(parsed.statements[2].sql == "CALL example()")
        #expect(parsed.statements.allSatisfy { !$0.sql.contains("DELIMITER") })
        for statement in parsed.statements { #expect((sql as NSString).substring(with: statement.range) == statement.sql) }
    }

    @Test func postgresSQLStandardAtomicRoutineBodyKeepsInternalStatementsAndCaseTogether() {
        let sql = """
        CREATE FUNCTION atomic_example() RETURNS integer LANGUAGE SQL
        BEGIN ATOMIC
          SELECT CASE WHEN true THEN 1 ELSE 2 END;
          SELECT 3;
        END;
        SELECT atomic_example();
        """
        let parsed = SQLScriptParser.parse(sql, engine: .postgresql)
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.statements.count == 2)
        #expect(parsed.statements[0].sql.contains("SELECT 3;"))
        #expect(parsed.statements[1].sql == "SELECT atomic_example()")
        #expect(!SQLScriptParser.parse("CREATE PROCEDURE p() LANGUAGE SQL BEGIN ATOMIC SELECT 1;", engine: .postgresql).diagnostics.isEmpty)
    }

    @Test func dialectSpecificEscapesAndCommentsDoNotHideStatementBoundaries() {
        let postgres = #"SELECT 'ends with slash\'; SELECT 2;"#
        #expect(SQLScriptParser.parse(postgres, engine: .postgresql).statements.count == 2)
        #expect(!SQLScriptParser.parse(postgres, engine: .mysql).diagnostics.isEmpty)
        let mysql = #"SELECT 'escaped\';semicolon'; SELECT 2;"#
        #expect(SQLScriptParser.parse(mysql, engine: .mysql).diagnostics.isEmpty)
        #expect(SQLScriptParser.parse(mysql, engine: .mysql).statements.count == 2)
        let comments = "SELECT 1--2; SELECT 3; # ; hidden\nSELECT 4; -- ; hidden\nSELECT 5;"
        #expect(SQLScriptParser.parse(comments, engine: .mysql).statements.count == 4)
        #expect(SQLScriptParser.parse("-- ;\n /* ; */ ;", engine: .postgresql).statements.isEmpty)
    }

    @Test func rangesAndSelectionUseUTF16OffsetsAfterUnicodeAndDirectiveLines() {
        let sql = "SELECT '😀';\n  SELECT 'κόσμος';"
        let parsed = SQLScriptParser.parse(sql, engine: .postgresql)
        let secondRange = (sql as NSString).range(of: "SELECT 'κόσμος'")
        #expect(parsed.statements[1].range == secondRange)
        #expect(parsed.statement(atUTF16: secondRange.location + 5) == parsed.statements[1])
        #expect(parsed.statement(atUTF16: sql.utf16.count) == parsed.statements[1])
        let selection = NSRange(location: secondRange.location - 2, length: secondRange.length + 2)
        #expect(SQLScriptParser.selectedStatement(in: sql, selection: selection, engine: .postgresql)?.range == secondRange)
        #expect(SQLScriptParser.selectedStatement(in: sql, selection: NSRange(location: 0, length: 0), engine: .postgresql) == parsed.statements[0])
        #expect(SQLScriptParser.selectedStatement(in: sql, selection: NSRange(location: NSNotFound, length: 0), engine: .postgresql) == nil)
    }

    @Test func unterminatedLexemesProvideRangesForEditorDiagnostics() {
        for sql in ["SELECT '😀", "SELECT \"identifier", "/* outer /* inner */", "DO $body$ BEGIN; END;"] {
            let parsed = SQLScriptParser.parse(sql, engine: .postgresql)
            #expect(parsed.diagnostics.count == 1)
            let range = parsed.diagnostics[0].range
            #expect(range.location >= 0 && NSMaxRange(range) == sql.utf16.count)
            #expect(range.length > 0)
        }
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func cursorImmediatelyAfterSemicolonStaysWithThePrecedingStatement(engine: DatabaseEngine) {
        let sql = "SELECT '😀';\n\nSELECT 'people';"
        let parsed = SQLScriptParser.parse(sql, engine: engine)
        let terminator = (sql as NSString).range(of: ";").location
        for location in [0, terminator, terminator + 1] {
            #expect(parsed.statement(atUTF16: location) == parsed.statements[0])
            #expect(SQLExecutionFragment.resolve(text: sql, selection: NSRange(location: location, length: 0),
                engine: engine)?.sourceSQL == "SELECT '😀'")
        }
        let second = (sql as NSString).range(of: "SELECT 'people'")
        #expect(parsed.statement(atUTF16: second.location) == parsed.statements[1])
        // With adjacent commands, the start of the next command takes priority.
        let adjacent = SQLScriptParser.parse("SELECT 1;SELECT 2;", engine: engine)
        #expect(adjacent.statement(atUTF16: 9) == adjacent.statements[1])
    }

    @Test func cursorInsideAndAfterMySQLDelimiterStaysWithTheRoutine() {
        let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\nSELECT 2;"
        let parsed = SQLScriptParser.parse(sql, engine: .mysql)
        let terminator = (sql as NSString).range(of: "END//").location + 3
        for location in terminator...(terminator + 2) {
            #expect(parsed.statement(atUTF16: location) == parsed.statements[0])
        }
        #expect(parsed.statements[0].sql == "CREATE PROCEDURE p() BEGIN SELECT 1; END")
        #expect(parsed.statements[1].sql == "SELECT 2")
    }

    @Test func clientCommandsAndStreamingImportsAreRejectedWithoutRejectingQuotedText() {
        for sql in [#"\d example"#, "SOURCE example.sql;", "COPY example FROM STDIN;", "COPY (SELECT 1) TO STDOUT;",
                    "LOAD DATA LOCAL INFILE 'example.csv' INTO TABLE example;",
                    "LOAD DATA LOW_PRIORITY LOCAL INFILE 'example.csv' INTO TABLE example;"] {
            let engine: DatabaseEngine = sql.hasPrefix("\\") || sql.hasPrefix("COPY") ? .postgresql : .mysql
            #expect(!SQLScriptParser.parse(sql, engine: engine).diagnostics.isEmpty)
        }
        #expect(SQLScriptParser.parse("SELECT 'COPY t FROM STDIN', 'SOURCE x.sql', '\\d';", engine: .postgresql).diagnostics.isEmpty)
        #expect(SQLScriptParser.parse("COPY example TO '/server/path';", engine: .postgresql).diagnostics.isEmpty)
        #expect(!SQLScriptParser.parse("DELIMITER $$\nSELECT 1$$", engine: .postgresql).diagnostics.isEmpty)
        #expect(!SQLScriptParser.parse("DELIMITER\nSELECT 1;", engine: .mysql).diagnostics.isEmpty)
    }
}
