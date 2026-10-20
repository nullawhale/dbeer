#![cfg_attr(
    all(target_os = "windows", not(debug_assertions), not(test)),
    windows_subsystem = "windows"
)]

#[cfg(test)]
extern crate gpui_kit as gpui;
#[cfg(test)]
#[path = "../vendor/gpui-pre-linux/src/linux/native_formats.rs"]
mod native_format_contract;

mod accessibility;
mod appearance;
mod appearance_settings;
mod assistance;
mod backend;
mod catalog;
mod changes_view;
mod close;
mod commands;
mod completion;
mod completion_view;
mod connections;
mod controls;
mod demo;
mod export_view;
mod exports;
#[cfg(test)]
mod fault_test_support;
#[cfg(feature = "native-smoke")]
mod feasibility;
mod file_view;
mod files;
mod grid_changes;
mod grid_clipboard;
mod grid_selection;
mod history_view;
mod instance;
mod language_service;
mod live;
#[cfg(test)]
mod live_tests;
mod model;
mod native_clipboard;
mod platform;
mod presentation;
mod preview;
mod preview_view;
mod product_identity;
mod profiles;
mod restoration;
mod results;
mod run_file_view;
mod run_to_file;
mod scripts;
mod session_end;
mod session_owner;
mod settings_view;
mod shortcut_settings;
mod shortcut_settings_view;
mod shortcuts;
mod signature;
mod signature_view;
#[cfg(feature = "native-smoke")]
mod smoke;
#[cfg(feature = "native-smoke")]
mod smoke_live;
#[cfg(all(feature = "native-smoke", target_os = "macos"))]
mod smoke_termination;
pub mod sql;
mod startup;
mod tables;
mod termination;
#[allow(unused_imports)]
mod theme_library;
#[allow(unused_imports)]
mod theme_library_view;
#[cfg(test)]
mod tls_tests;
mod transfer;
mod transfer_view;
mod workspace;
#[cfg(all(test, feature = "native-smoke"))]
mod workspace_tests;

use backend::BackendClient;
use catalog::CatalogSchema;
use close::CloseIntent;
use commands::{CommandId, CommandOrigin, DispatchCommand};
use connections::{ConnectionEditor, ConnectionProfile, ProfileStore};
use demo::{DemoTable, execute_fixture};
use gpui_kit::assets::IconName;
use gpui_kit::base::Disableable;
#[cfg(feature = "native-smoke")]
use gpui_kit::component::ThemeMode;
use gpui_kit::component::{
    ActiveTheme, Icon, Sizable, TitleBar, WindowExt,
    button::{Button, ButtonVariants},
    input::{Editor, EditorState, Input, InputEvent, InputState},
    resizable::{h_resizable, resizable_panel, v_resizable},
    table::{DataTable, TableState},
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;
use model::{DocumentId, DocumentState, OperationContext, ProfileId};
#[cfg(feature = "native-smoke")]
use presentation::apply_theme;
use results::ResultGrid;
use std::time::Duration;
#[cfg(feature = "native-smoke")]
use workspace::QueryTab;
use workspace::{Profile, Workspace};

fn main() {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match startup::build_info_request(&arguments) {
        Ok(true) => match product_identity::BuildInfo::gui_json() {
            Ok(json) => {
                println!("{json}");
                return;
            }
            Err(_) => {
                eprintln!("DBeer product build metadata is unavailable.");
                std::process::exit(2);
            }
        },
        Err(_) => {
            eprintln!("DBeer build metadata requires the exact --build-info argument.");
            std::process::exit(2);
        }
        Ok(false) => {}
    }
    #[cfg(feature = "native-smoke")]
    if feasibility::dispatch() {
        return;
    }
    #[cfg(not(feature = "native-smoke"))]
    if std::env::args_os().any(|arg| arg.to_string_lossy().starts_with("--feasibility-")) {
        eprintln!("Feasibility probes require the native-smoke build feature.");
        std::process::exit(2);
    }
    #[cfg(all(feature = "native-smoke", target_os = "macos"))]
    if let Some(code) = smoke_termination::run_supervisor() {
        std::process::exit(code);
    }
    // Only explicit Mac development fixtures are disposable. Product launches
    // require their native compiled identity before owning or loading any data.
    let launch = startup::LaunchOptions::current(&arguments).unwrap_or_else(|_| {
        eprintln!("DBeer startup arguments or native product identity are invalid. Extract a complete matching package.");
        std::process::exit(2);
    });
    let disposable = launch.disposable;
    let store = if disposable {
        None
    } else {
        match ProfileStore::default_path().and_then(ProfileStore::acquire) {
            Ok(store) => Some(store),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(2);
            }
        }
    };
    let startup = startup::load(launch.explicit_connection);
    application().with_assets(assets::AllAssets).run(move |cx| {
        cx.set_app_identity(
            product_identity::application_id(),
            product_identity::application_name(),
        );
        init(cx);
        let termination_requests = termination::install();

        commands::install_keys(cx);
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                None,
                size(px(1280.), px(820.)),
                cx,
            ))),
            window_min_size: Some(size(px(950.), px(620.))),
            app_id: Some(product_identity::application_id().into()),
            ..TitleBar::window_options()
        };
        let (window, view) = open_window(options, cx, |window, cx| {
            window.set_window_title(product_identity::application_name());
            cx.new(|cx| Workspace::new(store, launch.policy, window, cx))
        })
        .expect("Failed to open DBeer");
        if let Some(startup) = startup {
            window
                .update(cx, |_, window, cx| {
                    view.update(cx, |this, cx| {
                        this.start_explicit_connection(startup, window, cx)
                    });
                })
                .expect("Startup connection window");
        }
        window
            .update(cx, |_, window, cx| {
                close::install_window_guard(&view, window, cx);
                termination::install_window(window).expect("Native session-end guard");
                #[cfg(target_os = "linux")]
                if !disposable {
                    view.update(cx, |this, cx| this.start_desktop_session(window, cx));
                }
            })
            .expect("Window close guard");
        if let Some(termination_requests) = termination_requests {
            let weak_view = view.downgrade();
            cx.spawn(async move |cx| {
                while let Ok(request) = termination_requests.recv().await {
                    // This channel only carries requests that were vetoed before
                    // teardown. Forced session end never authorizes close success.
                    let _request_origin = request;
                    _ = window.update(cx, |_, window, cx| {
                        window.activate_window();
                        cx.activate(true);
                        // Repeated OS requests must preserve the current dialog,
                        // including transaction, SQL approval, and profile dialogs.
                        if !window.has_active_dialog(cx) {
                            _ = weak_view.update(cx, |this, cx| {
                                this.command(
                                    CommandId::Quit,
                                    CommandOrigin::System,
                                    None,
                                    window,
                                    cx,
                                )
                            });
                        }
                    });
                }
            })
            .detach();
        }
        #[cfg(feature = "native-smoke")]
        if std::env::args().any(|arg| arg == "--smoke-test") {
            window
                .update(cx, |_, window, cx| smoke::start(view.clone(), window, cx))
                .expect("Smoke window is available");
        }
        #[cfg(feature = "native-smoke")]
        if std::env::args().any(|arg| arg == "--live-smoke-test") {
            let smoke_view = view.clone();
            window
                .update(cx, |_, window, cx| {
                    smoke_live::start(smoke_view, window, cx)
                })
                .expect("Live smoke window");
        }
        #[cfg(all(feature = "native-smoke", target_os = "macos"))]
        if std::env::args().any(|arg| arg == "--termination-smoke-test") {
            window
                .update(cx, |_, window, cx| {
                    smoke_termination::start(view.clone(), window, cx)
                })
                .expect("Termination smoke window");
        }
        #[cfg(not(feature = "native-smoke"))]
        let _ = (window, view);
        cx.activate(true);
    });
}
