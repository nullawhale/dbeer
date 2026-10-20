//! Workspace presentation; rendering never replaces a document editor entity.
use super::*;
use gpui_kit::component::menu::{ContextMenuExt, DropdownMenu};

// Disposable probes/tests only. Production choices use the retained preferences owner.
#[cfg(feature = "native-smoke")]
pub(super) fn apply_theme(mode: ThemeMode, window: Option<&mut Window>, cx: &mut App) {
    let mut preferences = appearance::Preferences::default();
    preferences.choose_application(if mode.is_dark() { "dark" } else { "light" }, &[]);
    let resolved = preferences.resolve(appearance::Scheme::Dark, &[]);
    controls::publish_editor_palette(resolved.editor.clone(), cx);
    appearance::apply_application(&resolved, window, cx);
}

impl Workspace {
    pub(super) fn show_help(window: &mut Window, cx: &mut App) {
        window.open_dialog(cx, |dialog, _, _| dialog.title(product_identity::application_name()).accessibility_label(product_identity::application_name()).child(
            div().flex().flex_col().gap_3().text_sm()
                .child("A native Rust client using the existing DBeer Go helper. Add PostgreSQL/MySQL profiles with +. Passwords use your system credential store. Profiles start disconnected.")
                .child("Connect loads schemas; expand groups lazily for tables, views and routines. Double-click opens table data or object inspection. Catalog search uses the server across explicitly connected profiles. Each SQL tab has its own session. New profiles use an unspecified environment with readonly disabled. Write-enabled profiles use helper policy confirmations.")
                .child("Each tab retains its editor, results and filter. Column headers sort locally; column borders resize. Copy Rows copies the visible grid as quoted TSV, with \\N for SQL NULL.")
                .child(format!("{}: new tab / {}: close tab / {}: run selection or current statement / {}: catalog search. Query > Stop cancels the active operation. Appearance settings independently select application and SQL editor colors.", platform::shortcut("T"), platform::shortcut("W"), platform::shortcut("Enter"), platform::shortcut("F")))
        ));
    }

    pub(super) fn sidebar(&self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let query = self.search.read(cx).value().trim().to_lowercase();
        let mut catalog = div()
            .id("catalog")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p_2();
        if let Some(error) = &self.profile_error {
            catalog = catalog.child(div().p_2().text_sm().child(error.clone()));
        }
        if self.profiles.is_empty() {
            catalog = catalog.child(
                div()
                    .p_2()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child("No saved connections. Add a connection to get started."),
            );
        }
        for (index, profile) in self.profiles.iter().enumerate() {
            let id = profile.id.clone();
            let menu_id = id.clone();
            let saved = profile.config.is_some();
            let menu_view = cx.entity().downgrade();
            let button_view = menu_view.clone();
            catalog = catalog.child(
                div()
                    .id(SharedString::from(format!("profile-row-{}", id.0)))
                    .flex()
                    .items_center()
                    .gap_1()
                    .mb_1()
                    .rounded_md()
                    .when(index == self.selected_profile, |row| {
                        row.bg(cx.theme().secondary)
                    })
                    .child(
                        Button::new(("expand-profile", index))
                            .ghost()
                            .xsmall()
                            .icon(if profile.expanded {
                                IconName::ChevronDown
                            } else {
                                IconName::ChevronRight
                            })
                            .tooltip("Expand connection")
                            .disabled(self.closing)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if window.has_active_dialog(cx) {
                                    return;
                                }
                                this.profiles[index].expanded = !this.profiles[index].expanded;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new(("profile", index))
                            .ghost()
                            .small()
                            .flex_1()
                            .disabled(self.closing)
                            .accessibility_label(profile.name.clone())
                            .child(
                                div()
                                    .w_full()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(Icon::new(IconName::Database).small())
                                    .child(profile.name.clone())
                                    .child(
                                        div()
                                            .text_xs()
                                            .text_color(cx.theme().muted_foreground)
                                            .child(self.assistance_status()),
                                    )
                                    .when(
                                        self.assistance_status().contains("unavailable"),
                                        |view| {
                                            view.child(
                                                Button::new("retry-sql-assistance")
                                                    .small()
                                                    .label("Retry SQL Assistance")
                                                    .disabled(self.closing)
                                                    .on_click(cx.listener(
                                                        |this, _, window, cx| {
                                                            this.retry_assistance(window, cx)
                                                        },
                                                    )),
                                            )
                                        },
                                    ),
                            )
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if window.has_active_dialog(cx) {
                                    return;
                                }
                                let id = this.profiles[index].id.clone();
                                this.command(
                                    CommandId::SelectProfile,
                                    CommandOrigin::Button,
                                    Some(id),
                                    window,
                                    cx,
                                );
                                this.profiles[index].expanded = true;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new(("profile-actions", index))
                            .ghost()
                            .xsmall()
                            .icon(IconName::Ellipsis)
                            .tooltip("Connection actions")
                            .disabled(self.closing)
                            .dropdown_menu(move |menu, window, cx| {
                                Self::profile_menu(
                                    menu,
                                    button_view.clone(),
                                    menu_id.clone(),
                                    saved,
                                    window,
                                    cx,
                                )
                            }),
                    )
                    .child(
                        div()
                            .size(px(6.))
                            .rounded_full()
                            .mr_2()
                            .bg(if profile.loaded {
                                rgb(0x6daf79).into()
                            } else {
                                cx.theme().muted_foreground
                            }),
                    )
                    .context_menu(move |menu, window, cx| {
                        Self::profile_menu(menu, menu_view.clone(), id.clone(), saved, window, cx)
                    }),
            );
            if profile.expanded || !query.is_empty() {
                if profile.config.is_some() {
                    catalog = catalog.child(self.live_catalog(index, &query, cx));
                    continue;
                }
                if !self.document_profile_available(&profile.id) {
                    catalog =
                        catalog.child(div().ml_8().mb_2().text_xs().child(profile.status.clone()));
                    continue;
                }
                catalog = catalog.child(
                    div()
                        .ml_8()
                        .mb_2()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(format!("{} / PostgreSQL demo", profile.environment)),
                );
                catalog = catalog.child(
                    div()
                        .ml_6()
                        .mb_1()
                        .flex()
                        .gap_2()
                        .items_center()
                        .text_color(cx.theme().muted_foreground)
                        .child(Icon::new(IconName::ChevronDown).xsmall())
                        .child(Icon::new(IconName::Folder).small())
                        .child("public"),
                );
                for table in DemoTable::ALL {
                    if !query.is_empty() && !table.name().contains(&query) {
                        continue;
                    }
                    catalog = catalog.child(
                        Button::new(("table", index * 3 + table as usize))
                            .ghost()
                            .small()
                            .ml_9()
                            .w(px(175.))
                            .accessibility_label(table.name())
                            .child(
                                div()
                                    .w_full()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(Icon::new(IconName::Table).small())
                                    .child(table.name()),
                            )
                            .tooltip("Open sample SELECT in a new tab")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if this.closing || window.has_active_dialog(cx) {
                                    return;
                                }
                                let id = this.profiles[index].id.clone();
                                this.command(
                                    CommandId::SelectProfile,
                                    CommandOrigin::Button,
                                    Some(id),
                                    window,
                                    cx,
                                );
                                this.add_tab(table, window, cx);
                            })),
                    );
                }
            }
        }
        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(cx.theme().sidebar)
            .child(
                div()
                    .h(px(36.))
                    .px_3()
                    .flex()
                    .items_center()
                    .justify_between()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("Connections"))
                    .child(
                        Button::new("new-profile")
                            .ghost()
                            .xsmall()
                            .icon(IconName::Plus)
                            .tooltip("New PostgreSQL / MySQL connection")
                            .disabled(!self.command_enabled(CommandId::NewConnection, window, cx))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.command(
                                    CommandId::NewConnection,
                                    CommandOrigin::Button,
                                    None,
                                    window,
                                    cx,
                                );
                            })),
                    ),
            )
            .child(
                div()
                    .h(px(40.))
                    .px_2()
                    .flex()
                    .items_center()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(
                        Input::new(&self.search)
                            .small()
                            .prefix(Icon::new(IconName::Search).small())
                            .cleanable(true),
                    ),
            )
            .child(
                div()
                    .flex()
                    .gap_1()
                    .p_2()
                    .child(
                        Button::new("import-profiles")
                            .small()
                            .label("Import...")
                            .disabled(
                                self.closing
                                    || self.profile_store.is_none()
                                    || self.transfer_task.is_some(),
                            )
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.command(
                                    CommandId::ImportProfiles,
                                    CommandOrigin::Button,
                                    None,
                                    window,
                                    cx,
                                )
                            })),
                    )
                    .child(
                        Button::new("export-profiles")
                            .small()
                            .label("Export All...")
                            .disabled(
                                self.closing
                                    || self.transfer_task.is_some()
                                    || !self.profiles.iter().any(|p| p.config.is_some()),
                            )
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.command(
                                    CommandId::ExportAllProfiles,
                                    CommandOrigin::Button,
                                    None,
                                    window,
                                    cx,
                                )
                            })),
                    ),
            )
            .child(catalog)
            .child(
                div()
                    .p_3()
                    .border_t_1()
                    .border_color(cx.theme().border)
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child("CONNECTIONS")
                    .child(
                        div()
                            .mt_1()
                            .child("+ adds a real PostgreSQL / MySQL profile."),
                    ),
            )
    }

    pub(super) fn tab_bar(&self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .h(px(36.))
            .flex()
            .items_center()
            .border_b_1()
            .border_color(cx.theme().border)
            .bg(cx.theme().secondary)
            .child(
                div()
                    .id("sql-tabs")
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .overflow_x_scroll()
                    .children(self.tabs.iter().enumerate().map(|(index, tab)| {
                        div()
                            .flex()
                            .items_center()
                            .h(px(35.))
                            .px_1()
                            .border_r_1()
                            .border_color(cx.theme().border)
                            .when(index == self.active, |row| {
                                row.bg(cx.theme().background)
                                    .border_b_2()
                                    .border_color(cx.theme().primary)
                            })
                            .child(
                                Button::new(("tab", tab.id.0))
                                    .ghost()
                                    .small()
                                    .icon(IconName::File)
                                    .label(tab.title.clone())
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        if this.closing || window.has_active_dialog(cx) {
                                            return;
                                        }
                                        this.dismiss_completion();
                                        this.dismiss_signatures();
                                        this.active = index;
                                        this.schedule_documents(cx);
                                        this.tabs[index]
                                            .editor
                                            .update(cx, |state, cx| state.focus(window, cx));
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new(("close-tab", tab.id.0))
                                    .ghost()
                                    .xsmall()
                                    .icon(IconName::X)
                                    .tooltip("Close tab")
                                    .disabled(self.closing || window.has_active_dialog(cx))
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.command_for_document(
                                            CommandId::CloseTab,
                                            this.tabs[index].id,
                                            window,
                                            cx,
                                        )
                                    })),
                            )
                    })),
            )
            .child(
                Button::new("new-tab")
                    .ghost()
                    .small()
                    .icon(IconName::Plus)
                    .tooltip(format!("New SQL Tab ({})", platform::shortcut("T")))
                    .disabled(!self.command_enabled(CommandId::NewTab, window, cx))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.command(CommandId::NewTab, CommandOrigin::Button, None, window, cx)
                    })),
            )
    }

    pub(super) fn query_pane(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let tab = &self.tabs[self.active];
        if tab.catalog_document.is_some() {
            return self.catalog_document_pane(window, cx);
        }
        let profile = &self.profile(&tab.profile);
        let running = tab.busy();
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .h(px(40.))
                    .flex_none()
                    .px_3()
                    .flex()
                    .items_center()
                    .gap_2()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(
                        Icon::new(IconName::Database)
                            .small()
                            .text_color(cx.theme().primary),
                    )
                    .child(profile.name.clone())
                    .when(!self.document_profile_available(&tab.profile), |view| {
                        view.child(
                            Button::new("bind-selected-profile")
                                .small()
                                .label("Use Selected Connection")
                                .disabled(
                                    self.closing
                                        || self
                                            .profiles
                                            .get(self.selected_profile)
                                            .is_none_or(|profile| profile.config.is_none()),
                                )
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.bind_selected_document_profile(cx)
                                })),
                        )
                    })
                    .child(
                        div()
                            .text_xs()
                            .px_2()
                            .py_0p5()
                            .rounded_sm()
                            .bg(cx.theme().secondary)
                            .text_color(cx.theme().muted_foreground)
                            .child(profile.environment),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .child(if let Some(config) = &profile.config {
                                if config.readonly {
                                    "Read-only"
                                } else {
                                    "Writes enabled"
                                }
                            } else {
                                "Read-only demo"
                            }),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("disconnect")
                            .ghost()
                            .small()
                            .label(if profile.config.is_some() && !profile.loaded {
                                "Connect"
                            } else {
                                "Disconnect"
                            })
                            .disabled(
                                self.closing
                                    || profile.task.is_some()
                                    || !self.document_profile_available(&profile.id),
                            )
                            .on_click(cx.listener(|this, _, window, cx| {
                                let profile = this.profile(&this.tabs[this.active].profile);
                                let command = if profile.config.is_some() && !profile.loaded {
                                    CommandId::Connect
                                } else {
                                    CommandId::Disconnect
                                };
                                let id = profile.id.clone();
                                this.command(command, CommandOrigin::Button, Some(id), window, cx);
                            })),
                    )
                    .child(
                        Button::new("stop")
                            .ghost()
                            .small()
                            .icon(IconName::Square)
                            .label(self.shortcut_label(CommandId::Stop, "Stop"))
                            .tooltip(self.command_label(CommandId::Stop))
                            .disabled(!self.command_enabled(CommandId::Stop, window, cx))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.command(
                                    CommandId::Stop,
                                    CommandOrigin::Button,
                                    None,
                                    window,
                                    cx,
                                )
                            })),
                    )
                    .child(
                        Button::new("run-script")
                            .ghost()
                            .small()
                            .label(self.shortcut_label(CommandId::RunScript, "Run Script"))
                            .tooltip(self.command_label(CommandId::RunScript))
                            .disabled(!self.command_enabled(CommandId::RunScript, window, cx))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.command(
                                    CommandId::RunScript,
                                    CommandOrigin::Button,
                                    None,
                                    window,
                                    cx,
                                )
                            })),
                    )
                    .child(
                        Button::new("run")
                            .primary()
                            .small()
                            .icon(IconName::Play)
                            .label(if running {
                                "Running...".to_owned()
                            } else {
                                self.shortcut_label(CommandId::RunCurrent, "Run")
                            })
                            .tooltip(self.command_label(CommandId::RunCurrent))
                            .disabled(!self.command_enabled(CommandId::RunCurrent, window, cx))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.command(
                                    CommandId::RunCurrent,
                                    CommandOrigin::Button,
                                    None,
                                    window,
                                    cx,
                                )
                            })),
                    ),
            )
            .child(
                div().flex_1().min_h_0().child(
                    v_resizable("editor-result-split")
                        .child(
                            resizable_panel()
                                .size(px(260.))
                                .size_range(px(130.)..px(900.))
                                .child(
                                    div()
                                        .size_full()
                                        .flex()
                                        .flex_col()
                                        .child(
                                            div()
                                                .h(px(30.))
                                                .px_4()
                                                .flex()
                                                .items_center()
                                                .justify_between()
                                                .text_xs()
                                                .text_color(cx.theme().muted_foreground)
                                                .child("SQL EDITOR")
                                                .child(if let Some(config) = &profile.config {
                                                    format!(
                                                        "{} / UTF-8 / {}",
                                                        config.display_engine(),
                                                        tab.transaction
                                                    )
                                                } else {
                                                    "PostgreSQL demo / UTF-8".into()
                                                }),
                                        )
                                        .child(
                                            div()
                                                .flex_1()
                                                .min_h_0()
                                                .key_context(self.shortcut_input_context())
                                                .child(controls::sql_editor_feedback(
                                                    &tab.editor,
                                                    tab.successful_ranges.clone(),
                                                    self.close_flow.as_ref().is_some_and(|flow| {
                                                        flow.phase == close::ClosePhase::Finishing
                                                    }),
                                                    self.editor_palette(cx),
                                                    tab.accessibility_guard.clone(),
                                                    tab.id,
                                                )),
                                        ),
                                ),
                        )
                        .child(
                            resizable_panel()
                                .size_range(px(160.)..px(1800.))
                                .child(self.results_pane(window, cx)),
                        ),
                ),
            )
            .into_any_element()
    }

    pub(super) fn results_pane(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let tab = &self.tabs[self.active];
        let counts = tab
            .grid
            .as_ref()
            .map(|grid| {
                let d = grid.read(cx).delegate();
                format!("{} of {} rows", d.row_count(), d.total_count())
            })
            .unwrap_or_else(|| "No results".into());
        let mut pane = div().flex().flex_col().size_full().min_h_0().child(
            div()
                .h(px(40.))
                .flex_none()
                .flex()
                .items_center()
                .px_3()
                .gap_3()
                .border_b_1()
                .border_color(cx.theme().border)
                .child(
                    Icon::new(IconName::Table)
                        .small()
                        .text_color(cx.theme().primary),
                )
                .child(div().font_weight(FontWeight::MEDIUM).child(
                    if matches!(tab.kind, model::DocumentKind::Table { .. }) {
                        "Loaded page: local sort / filter"
                    } else {
                        "Results: local sort / filter"
                    },
                ))
                .when(tab.result_sets.len() > 1, |row| {
                    row.child(
                        Button::new("result-set")
                            .ghost()
                            .small()
                            .label(format!(
                                "Statement {} / set {} of {}",
                                tab.selected_execution + 1,
                                tab.selected_result + 1,
                                tab.result_sets.len()
                            ))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.command(
                                    CommandId::NextResult,
                                    CommandOrigin::Button,
                                    None,
                                    window,
                                    cx,
                                )
                            })),
                    )
                })
                .child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(counts),
                )
                .when(tab.error_position.is_some(), |row| {
                    let id = tab.id;
                    row.child(
                        Button::new("go-to-sql-error")
                            .ghost()
                            .small()
                            .label("Go to Error")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.navigate_execution_error(id, window, cx)
                            })),
                    )
                })
                .child(div().flex_1())
                .child(
                    div().w(px(210.)).child(
                        Input::new(&tab.filter)
                            .aria_label("Filter loaded result rows")
                            .accessibility_id(format!("dbeer-result-filter-{}", tab.id.0))
                            .small()
                            .prefix(Icon::new(IconName::Search).small())
                            .cleanable(true),
                    ),
                )
                .child(
                    Button::new("export-loaded-json")
                        .ghost()
                        .small()
                        .label("JSON...")
                        .disabled(!self.command_enabled(CommandId::ExportResultsJson, window, cx))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.command(
                                CommandId::ExportResultsJson,
                                CommandOrigin::Button,
                                None,
                                window,
                                cx,
                            )
                        })),
                )
                .child(
                    Button::new("export-loaded-csv")
                        .ghost()
                        .small()
                        .label("CSV...")
                        .disabled(!self.command_enabled(CommandId::ExportResultsCsv, window, cx))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.command(
                                CommandId::ExportResultsCsv,
                                CommandOrigin::Button,
                                None,
                                window,
                                cx,
                            )
                        })),
                )
                .child(
                    Button::new("grid-selection-copy")
                        .ghost()
                        .small()
                        .label("Copy Selection")
                        .disabled(!self.command_enabled(CommandId::GridCopy, window, cx))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.command(
                                CommandId::GridCopy,
                                CommandOrigin::Button,
                                None,
                                window,
                                cx,
                            )
                        })),
                )
                .child(
                    Button::new("grid-details")
                        .ghost()
                        .small()
                        .label("Row Details")
                        .disabled(tab.grid.is_none())
                        .on_click(cx.listener(|this, _, window, cx| {
                            if let Some(grid) =
                                this.tabs.get(this.active).and_then(|tab| tab.grid.clone())
                            {
                                grid.update(cx, |table, cx| {
                                    table.delegate_mut().details_open =
                                        !table.delegate().details_open;
                                    table.delegate_mut().sync_details(window, cx);
                                    cx.notify();
                                });
                            }
                        })),
                )
                .child(
                    Button::new("copy-rows")
                        .ghost()
                        .small()
                        .icon(IconName::Copy)
                        .label("Copy Rows")
                        .disabled(!self.command_enabled(CommandId::CopyRows, window, cx))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.command(
                                CommandId::CopyRows,
                                CommandOrigin::Button,
                                None,
                                window,
                                cx,
                            );
                        })),
                ),
        );
        if matches!(tab.kind, model::DocumentKind::Table { .. }) {
            pane = pane.child(self.changes_controls(tab.id, window, cx));
        }
        if !tab.executions.is_empty() {
            let id = tab.id;
            let operation = tab.executions[0].operation;
            pane = pane.child(
                div()
                    .id("statement-outcomes")
                    .flex()
                    .flex_none()
                    .h(px(36.))
                    .overflow_x_scroll()
                    .gap_1()
                    .children(tab.executions.iter().enumerate().map(|(index, execution)| {
                        let line = tab
                            .execution_source
                            .as_ref()
                            .map(|f| {
                                f.source().text()[..execution.source_range.start]
                                    .bytes()
                                    .filter(|b| *b == b'\n')
                                    .count()
                                    + 1
                            })
                            .unwrap_or(1);
                        Button::new(("statement-outcome", index))
                            .ghost()
                            .small()
                            .label(format!(
                                "{} / line {} / {:?} / {} rows / {:.1} ms{}",
                                index + 1,
                                line,
                                execution.state,
                                execution.row_count,
                                execution.duration_ms,
                                if execution.truncated {
                                    " / truncated"
                                } else {
                                    ""
                                }
                            ))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                let Some(tab) = this.tabs.iter_mut().find(|t| {
                                    t.id == id
                                        && t.executions
                                            .first()
                                            .is_some_and(|e| e.operation == operation)
                                }) else {
                                    return;
                                };
                                let Some(execution) = tab.executions.get(index) else {
                                    return;
                                };
                                tab.selected_result = execution.results.start;
                                tab.selected_execution = index;
                                this.render_live_result(id, window, cx);
                                cx.notify();
                            }))
                    })),
            );
        }
        if let Some(grid) = &tab.grid {
            pane = pane.child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .key_context("DBeerGrid")
                            .on_action({
                                let grid = grid.clone();
                                move |action: &results::interaction::Navigate, window, cx| {
                                    results::interaction::navigate(&grid, action, window, cx)
                                }
                            })
                            .on_action({
                                let grid = grid.clone();
                                move |_: &gpui_kit::component::input::SelectAll, window, cx| {
                                    results::interaction::select_all(&grid, window, cx)
                                }
                            })
                            .on_mouse_up_out(MouseButton::Left, {
                                let grid = grid.clone();
                                move |_, _, cx| {
                                    grid.update(cx, |table, _| {
                                        table.delegate_mut().drag_active = false
                                    })
                                }
                            })
                            .on_action(cx.listener(
                                |this, _: &gpui_kit::component::input::Copy, window, cx| {
                                    this.command(
                                        CommandId::GridCopy,
                                        CommandOrigin::Shortcut,
                                        None,
                                        window,
                                        cx,
                                    );
                                },
                            ))
                            .child(
                                DataTable::new(grid)
                                    .small()
                                    .header_row_height(px(42.))
                                    .stripe(true),
                            ),
                    )
                    .when(grid.read(cx).delegate().details_open, |view| {
                        view.child(grid.read(cx).delegate().details_view(cx))
                    }),
            );
        } else if let Some(set) = tab.result_sets.get(tab.selected_result).filter(|set| {
            set.columns.is_empty()
                && tab
                    .executions
                    .get(tab.selected_execution)
                    .is_some_and(|e| e.results.contains(&tab.selected_result))
        }) {
            pane = pane.child(div().flex_1().flex().items_center().justify_center().child(
                format!(
                    "{} / {} affected rows{}",
                    set.command_tag,
                    set.row_count,
                    if set.truncated {
                        " / display truncated"
                    } else {
                        ""
                    }
                ),
            ));
        } else if let Some(execution) = tab
            .executions
            .get(tab.selected_execution)
            .filter(|e| e.failure.is_some())
        {
            pane = pane.child(
                div()
                    .flex_1()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(execution.failure.clone().unwrap_or_default()),
            );
        } else {
            pane = pane.child(div().flex_1().min_h_0().flex().flex_col().items_center().justify_center().gap_3().px_8()
                .child(Icon::new(if tab.error { IconName::Info } else { IconName::Database }).size_8().text_color(cx.theme().muted_foreground))
                .child(if tab.task.is_some() { "Executing query..." } else if tab.error { "Query failed" } else { "Your results will appear here" })
                .child(div().max_w(px(560.)).text_center().text_sm().text_color(cx.theme().muted_foreground)
                    .child(if tab.error { tab.status.clone() } else { "Run SQL from the editor. Real profiles connect only after Connect or Run; demo profiles use local fixtures.".into() })));
        }
        pane.child(
            div()
                .h(px(30.))
                .flex_none()
                .flex()
                .items_center()
                .px_3()
                .border_t_1()
                .border_color(cx.theme().border)
                .text_xs()
                .text_color(cx.theme().muted_foreground)
                .child("Read-only results")
                .child(div().flex_1())
                .child(
                    tab.result_sets
                        .get(tab.selected_result)
                        .map(|set| set.display_notice.clone())
                        .filter(|notice| !notice.is_empty())
                        .unwrap_or_else(|| "Sort and filter apply to loaded rows".into()),
                ),
        )
    }
}

impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.prepare_native_owners(cx);
        self.sync_assistance(cx);
        // Action availability reads the completed dispatch tree. The initial
        // render has no previous tree, so publish menus after this effect cycle.
        if cfg!(target_os = "macos") {
            cx.defer_in(window, |this, window, cx| {
                this.refresh_native_menus(window, cx);
            });
        }
        let completion = self.completion_overlay(window, cx);
        let signatures = self.signature_overlay(window, cx);
        let status = self
            .restoration
            .error
            .clone()
            .map(SharedString::from)
            .unwrap_or_else(|| {
                self.tabs
                    .get(self.active)
                    .map(|t| t.status.clone())
                    .unwrap_or_else(|| "No SQL documents. Open a file or create a SQL tab.".into())
            });
        div()
            .id("dbeer-workspace")
            .role(Role::Window)
            .accessibility_id("dbeer-workspace")
            .aria_label("DBeer SQL workspace")
            .key_context("DBeerWorkspace")
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .font_family(cx.theme().font_family.clone())
            .text_size(px(13.))
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .on_action(cx.listener(|this, action: &DispatchCommand, window, cx| {
                this.command(action.command, CommandOrigin::Shortcut, None, window, cx);
            }))
            .capture_key_down(cx.listener(|this, event, window, cx| {
                this.invalidate_native_actions(cx);
                this.completion_key(event, window, cx);
                this.shortcut_key(event, window, cx);
                this.forward_native_input_alias(event, window, cx);
            }))
            .capture_any_mouse_down(cx.listener(|this, _, _, cx| this.invalidate_native_actions(cx)))
            .children(completion)
            .children(signatures)
            .child(
                TitleBar::new()
                    .on_close_window(cx.listener(|this, _, window, cx| {
                        this.command(CommandId::Quit, CommandOrigin::System, None, window, cx)
                    }))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .size_full()
                            .gap_2()
                            .pr_2()
                            .child(Icon::new(IconName::Database).text_color(cx.theme().primary))
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("DBeer"))
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(cx.theme().muted_foreground)
                                    .child(if cfg!(target_os = "macos") { "GPUI development" } else { "Development build" }),
                            )
                            .child(div().flex_1())
                            .child(
                                Button::new("help")
                                    .ghost()
                                    .small()
                                    .icon(IconName::Info)
                                    .tooltip("About DBeer")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.command(
                                            CommandId::About,
                                            CommandOrigin::Button,
                                            None,
                                            window,
                                            cx,
                                        )
                                    })),
                            )
                            .child(
                                Button::new("theme")
                                    .ghost()
                                    .small()
                                    .icon(if cx.theme().mode.is_dark() {
                                        IconName::Sun
                                    } else {
                                        IconName::Moon
                                    })
                                    .tooltip("Toggle light / dark")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.command(
                                            CommandId::ToggleTheme,
                                            CommandOrigin::Button,
                                            None,
                                            window,
                                            cx,
                                        )
                                    })),
                            ),
                    ),
            )
            .when(!cfg!(target_os = "macos"), |this| {
                this.child(self.command_menu_bar(cx))
            })
            .child(
                div().flex_1().min_h_0().child(
                    h_resizable("workspace-split")
                        .child(
                            resizable_panel()
                                .size(px(260.))
                                .size_range(px(220.)..px(400.))
                                .child(self.sidebar(window, cx)),
                        )
                        .child(
                            resizable_panel().size_range(px(650.)..px(2500.)).child(
                                div()
                                    .size_full()
                                    .flex()
                                    .flex_col()
                                    .child(self.tab_bar(window, cx))
                                    .child(
                                        div().flex_1().min_h_0().when(!self.tabs.is_empty(), |view| view.child(self.query_pane(window, cx)))
                                            .when(self.tabs.is_empty(), |view| view.p_4().child("No SQL documents. Open a file or create a SQL tab.")),
                                    ),
                            ),
                        ),
                ),
            )
            .child(
                div()
                    .h(px(28.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .px_3()
                    .gap_2()
                    .border_t_1()
                    .border_color(cx.theme().border)
                    .bg(cx.theme().secondary)
                    .text_xs()
                    .child(div().size(px(5.)).rounded_full().bg(cx.theme().primary))
                    .child(status)
                    .child(div().flex_1())
                    .child(
                        div()
                            .text_color(cx.theme().muted_foreground)
                            .child("GPUI Kit / Go helper / PostgreSQL + MySQL"),
                    ),
            )
    }
}
