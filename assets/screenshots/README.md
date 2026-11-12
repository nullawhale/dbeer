# README screenshots

`workspace-light.webp` and `workspace-dark.webp` are real captures of the native
macOS development build from October 27, 2026, using a disposable PostgreSQL 17
database and synthetic beer inventory data. Both are 2560 × 1600 lossless WebP
images copied unchanged from the [landing page repository](https://github.com/nullawhale/dbeer-landing),
where the scene is named `queries`.

To capture updated images, build the app and run `scripts/capture-screenshots.sh`
from the repository root. Set `DBEER_CAPTURE_APPEARANCE=light` for Lager and
`DBEER_CAPTURE_APPEARANCE=dark` for Porter. The runner requires Docker and an
interactive macOS session; capture only when explicitly requested.
