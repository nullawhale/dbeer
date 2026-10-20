//! Prepared headless contract, not native desktop or settings UI evidence.
use super::*;
use gpui_kit::component::table::TableState;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{AppContext, TestAppContext, point, px};

#[gpui_kit::test]
fn palette_application_preserves_retained_source_undo_grid_and_operation(cx: &mut TestAppContext) {
    let (window, view) = crate::workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        let editor = view.read(cx).tabs[0].editor.clone();
        editor.update(cx, |state, cx| {
            state.set_value(
                (0..90)
                    .map(|i| format!("SELECT {i};\n"))
                    .collect::<String>(),
                window,
                cx,
            );
            state.set_selected_range(0..0, cx);
            state.focus(window, cx);
        });
        window.render_frame(cx);
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string("-- retained\n".into()));
        window.press(&crate::platform::binding("v"), cx);
        editor.update(cx, |state, cx| {
            state.set_selected_range(4..10, cx);
            state.set_scroll_offset(point(px(-10.), px(-80.)), cx);
        });
        window.render_frame(cx);
        let text = editor.read(cx).value();
        let selection = editor.read(cx).selected_range();
        let scroll = editor.read(cx).scroll_offset();
        let result = crate::demo::QueryResult {
            columns: crate::demo::DemoTable::Products.columns(),
            rows: crate::demo::DemoTable::Products.rows(),
        };
        let mut delegate = crate::results::ResultGrid::new(result);
        delegate.selection.select(
            &[1, 2],
            crate::grid_selection::CellPoint { row: 2, column: 1 },
            false,
            false,
            7,
        );
        let grid_selection = delegate.selection.clone();
        let grid = cx.new(|cx| TableState::new(delegate, window, cx));
        let (document, context, persistent_id) = view.update(cx, |this, _| {
            let tab = &mut this.tabs[0];
            tab.grid = Some(grid.clone());
            let context = tab.begin(None, text.len()).unwrap();
            let context = tab
                .attach(&context, "appearance-owned-session".into())
                .unwrap();
            tab.started(&context, "appearance-owned-query".into());
            (tab.id, context, tab.persistent_id.clone())
        });
        let themes = [Theme::native(Scheme::Light), Theme::native(Scheme::Dark)];
        let mut preferences = Preferences::default();
        for (app, sql) in [
            ("dark", "native-light"),
            ("native-light", "native-dark"),
            ("system", "automatic"),
        ] {
            preferences.choose_application(app, &themes);
            preferences.choose_editor(sql, &themes);
            let resolved = preferences.resolve(Scheme::Dark, &themes);
            apply_application(&resolved, Some(window), cx);
            editor.update(cx, |state, _| {
                state.set_editor_style(resolved.editor.input_style())
            });
            let tab = &view.read(cx).tabs[0];
            assert_eq!(tab.id, document);
            assert_eq!(tab.persistent_id, persistent_id);
            assert_eq!(tab.editor.entity_id(), editor.entity_id());
            assert_eq!(tab.grid.as_ref().unwrap().entity_id(), grid.entity_id());
            assert!(tab.owns(&context));
            assert!(tab.busy());
            assert_eq!(tab.query_id.as_deref(), Some("appearance-owned-query"));
            assert_eq!(editor.read(cx).value(), text);
            assert_eq!(editor.read(cx).selected_range(), selection);
            assert_eq!(editor.read(cx).scroll_offset(), scroll);
            assert_eq!(grid.read(cx).delegate().selection, grid_selection);
        }
        // End only the synthetic operation, then invoke the same editor's Undo.
        view.update(cx, |this, _| {
            this.tabs[0].phase = None;
            this.tabs[0].operation = None;
        });
        window.press(&crate::platform::binding("z"), cx);
        assert!(!editor.read(cx).value().starts_with("-- retained"));
    })
    .unwrap();
}
