//! Opt-in checks against a real GPUI window and its rendered Metal scene.

use super::*;
use std::path::{Path, PathBuf};

type SmokeResult<T> = Result<T, String>;

pub(super) fn start(view: Entity<Workspace>, window: &mut Window, cx: &mut App) {
    window
        .spawn(cx, async move |cx| {
            match run(view, cx).await {
                Ok(passed) => println!("Native smoke: {passed} checks passed; completed."),
                Err(error) => {
                    eprintln!("Native smoke FAILED: {error}");
                    _ = cx.update(|_, cx| cx.quit());
                    std::process::exit(1);
                }
            }
            _ = cx.update(|_, cx| cx.quit());
        })
        .detach();
}

async fn pause(cx: &AsyncWindowContext, milliseconds: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(milliseconds))
        .await;
}

fn check(passed: &mut usize, name: &str, condition: bool) -> SmokeResult<()> {
    if !condition {
        return Err(name.into());
    }
    *passed += 1;
    println!("  PASS {name}");
    Ok(())
}

fn row_count(tab: &QueryTab, cx: &App) -> Option<usize> {
    tab.grid
        .as_ref()
        .map(|grid| grid.read(cx).delegate().row_count())
}

fn snapshot(window: &Window, path: &Path, dark: bool) -> SmokeResult<()> {
    if window.painted_quads().is_empty() {
        return Err("Snapshot has no painted scene".into());
    }
    let image = window
        .render_to_image()
        .map_err(|error| error.to_string())?;
    let count = u64::from(image.width()) * u64::from(image.height());
    if count == 0 {
        return Err("Snapshot has no pixels".into());
    }
    let brightness = image
        .pixels()
        .map(|pixel| (u64::from(pixel.0[0]) + u64::from(pixel.0[1]) + u64::from(pixel.0[2])) / 3)
        .sum::<u64>()
        / count;
    if (dark && brightness >= 120) || (!dark && brightness <= 140) {
        return Err(format!(
            "Snapshot theme is stale: average brightness {brightness}"
        ));
    }
    image.save(path).map_err(|error| error.to_string())?;
    println!(
        "  Saved {} ({}x{}, brightness {brightness})",
        path.display(),
        image.width(),
        image.height()
    );
    Ok(())
}

async fn run(view: Entity<Workspace>, cx: &mut AsyncWindowContext) -> SmokeResult<usize> {
    let output = std::env::var_os("DBEER_GPUI_SMOKE_OUTPUT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../build/gpui/qa"));
    std::fs::create_dir_all(&output).map_err(|error| error.to_string())?;
    let summary_path = output.join("summary.txt");
    if summary_path.exists() {
        std::fs::remove_file(&summary_path).map_err(|error| error.to_string())?;
    }
    let mut passed = 0;
    pause(cx, 250).await;
    view.update_in(cx, |this, window, cx| {
        check(
            &mut passed,
            "startup is disconnected with no results",
            this.profiles.iter().all(|profile| !profile.loaded)
                && this.tabs.len() == 1
                && this.tabs[0].grid.is_none(),
        )?;
        check(
            &mut passed,
            "startup focuses the SQL editor",
            this.tabs[0]
                .editor
                .focus_handle(cx)
                .contains_focused(window, cx),
        )?;
        window.dispatch_action(
            Box::new(DispatchCommand {
                command: CommandId::RunCurrent,
            }),
            cx,
        );
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 750).await;
    view.update_in(cx, |this, _, cx| {
        check(
            &mut passed,
            "Run loads 24 product rows",
            row_count(&this.tabs[0], cx) == Some(24)
                && this.tabs[0].task.is_none()
                && !this.tabs[0].error,
        )
    })
    .map_err(|error| error.to_string())??;
    cx.update(|window, _| snapshot(window, &output.join("dark.png"), true))
        .map_err(|error| error.to_string())??;
    passed += 1;
    let original = view
        .update_in(cx, |this, window, cx| {
            let original = this.tabs[0].editor.read(cx).value().to_string();
            this.toggle_theme(window, cx);
            original
        })
        .map_err(|error| error.to_string())?;
    pause(cx, 250).await;
    view.update_in(cx, |this, _, cx| {
        check(
            &mut passed,
            "theme change preserves the SQL editor",
            !cx.theme().mode.is_dark() && this.tabs[0].editor.read(cx).value().as_ref() == original,
        )
    })
    .map_err(|error| error.to_string())??;
    cx.update(|window, _| snapshot(window, &output.join("light.png"), false))
        .map_err(|error| error.to_string())??;
    passed += 1;
    view.update_in(cx, |this, window, cx| {
        this.add_tab(DemoTable::Customers, window, cx);
        check(
            &mut passed,
            "new customer tab has independent SQL and no results",
            this.active == 1
                && this.tabs[1].editor.read(cx).value().as_ref() == DemoTable::Customers.query()
                && this.tabs[1].grid.is_none()
                && row_count(&this.tabs[0], cx) == Some(24),
        )?;
        this.search.update(cx, |input, cx| input.focus(window, cx));
        window.dispatch_action(
            Box::new(DispatchCommand {
                command: CommandId::RunCurrent,
            }),
            cx,
        );
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 250).await;
    view.update_in(cx, |this, window, cx| {
        check(
            &mut passed,
            "Run action ignores catalog search focus",
            this.tabs[1].grid.is_none() && this.tabs[1].task.is_none(),
        )?;
        this.tabs[1]
            .editor
            .update(cx, |editor, cx| editor.focus(window, cx));
        window.dispatch_action(
            Box::new(DispatchCommand {
                command: CommandId::RunCurrent,
            }),
            cx,
        );
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 750).await;
    view.update_in(cx, |this, window, cx| {
        check(
            &mut passed,
            "customer Run retains product results",
            row_count(&this.tabs[1], cx) == Some(24) && row_count(&this.tabs[0], cx) == Some(24),
        )?;
        // replace_all emits the real input change event; set_value does not.
        this.tabs[1]
            .filter
            .update(cx, |input, cx| input.replace_all("ALDER", window, cx));
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 250).await;
    view.update_in(cx, |this, _, cx| {
        check(
            &mut passed,
            "filter input subscription updates only its tab",
            row_count(&this.tabs[1], cx) == Some(1) && row_count(&this.tabs[0], cx) == Some(24),
        )?;
        this.active = 0;
        cx.notify();
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 250).await;
    view.update_in(cx, |this, window, cx| {
        check(
            &mut passed,
            "switching tabs retains SQL and filter",
            this.tabs[0].editor.read(cx).value().as_ref() == original
                && this.tabs[0].filter.read(cx).value().is_empty(),
        )?;
        this.active = 1;
        this.run_query(window, cx);
        this.stop_query(cx);
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 750).await;
    view.update_in(cx, |this, window, cx| {
        check(
            &mut passed,
            "cancellation prevents delayed results",
            this.tabs[1].grid.is_none()
                && this.tabs[1].task.is_none()
                && this.tabs[1].status.contains("cancelled"),
        )?;
        this.run_query(window, cx);
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 750).await;
    view.update_in(cx, |this, window, cx| {
        check(
            &mut passed,
            "rerun restores results with its retained filter",
            row_count(&this.tabs[1], cx) == Some(1),
        )?;
        this.tabs[1]
            .editor
            .update(cx, |editor, cx| editor.replace_all("SELECT 1;", window, cx));
        Ok::<_, String>(())
    })
    .map_err(|error| error.to_string())??;
    pause(cx, 250).await;
    view.update_in(cx, |this, window, cx| this.run_query(window, cx))
        .map_err(|error| error.to_string())?;
    pause(cx, 750).await;
    view.update_in(cx, |this, _, cx| {
        check(
            &mut passed,
            "unsupported SQL clears results and reports a demo error",
            this.tabs[1].grid.is_none()
                && this.tabs[1].error
                && this.tabs[1].status.contains("no database connection"),
        )?;
        check(
            &mut passed,
            "other tab results survive cancellation and SQL errors",
            row_count(&this.tabs[0], cx) == Some(24),
        )
    })
    .map_err(|error| error.to_string())??;
    std::fs::write(
        &summary_path,
        format!(
            "Native smoke: {passed} checks passed; completed.\nSnapshots: dark.png, light.png\n"
        ),
    )
    .map_err(|error| error.to_string())?;
    Ok(passed)
}
