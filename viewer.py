#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

SOURCE_POLL_INTERVAL = 0.1
SOURCE_SETTLE_DELAY = 0.35


HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LaTeX XDV Viewer</title>
  <style>
    :root {
      --bg: #ffffff;
      --panel: rgba(255, 255, 255, 0.96);
      --ink: #1e1b18;
      --muted: #6e655d;
      --accent: #1d5f5a;
      --accent-2: #d98c3f;
      --line: rgba(30, 27, 24, 0.12);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      color: var(--ink);
      background: var(--bg);
      font-family: Georgia, "Iowan Old Style", "Palatino Linotype", serif;
    }
    .shell {
      min-height: 100vh;
      display: grid;
      grid-template-rows: auto 1fr;
    }
    .toolbar {
      position: sticky;
      top: 0;
      z-index: 10;
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem;
      align-items: center;
      padding: 1rem 1.25rem;
      background: var(--panel);
      border-bottom: 1px solid var(--line);
    }
    .toolbar-group {
      display: flex;
      gap: 0.5rem;
      align-items: center;
    }
    button, input {
      font: inherit;
      border-radius: 999px;
      border: 1px solid var(--line);
      padding: 0.6rem 0.95rem;
      background: white;
      color: var(--ink);
    }
    button {
      cursor: pointer;
      transition: transform 120ms ease, background 120ms ease;
    }
    button:hover { transform: translateY(-1px); }
    button.primary {
      background: var(--accent);
      color: white;
      border-color: transparent;
    }
    button.secondary {
      background: #fff7ef;
      border-color: rgba(217, 140, 63, 0.28);
    }
    input[type="number"] {
      width: 5rem;
      text-align: center;
    }
    .meta {
      min-width: 18rem;
      flex: 1;
      color: var(--muted);
      font-size: 0.95rem;
    }
    .stage {
      padding: 1.5rem;
      display: grid;
      place-items: start center;
    }
    .pages {
      display: flex;
      gap: 1.25rem;
      align-items: flex-start;
      justify-content: center;
      flex-wrap: nowrap;
      width: 100%;
    }
    .page {
      max-width: calc(100vw - 3rem);
      box-shadow: none;
      background: transparent;
    }
    .empty {
      margin-top: 12vh;
      width: min(42rem, calc(100vw - 3rem));
      padding: 2rem;
      background: rgba(255, 255, 255, 0.78);
      border: 1px solid var(--line);
      border-radius: 1.25rem;
      box-shadow: 0 1rem 2rem rgba(30, 27, 24, 0.08);
    }
    .empty h1 {
      margin-top: 0;
      font-size: clamp(2rem, 4vw, 3.2rem);
      line-height: 0.95;
    }
    .status {
      color: var(--muted);
      font-size: 0.95rem;
    }
    .error {
      color: #922d1f;
      white-space: pre-wrap;
    }
  </style>
</head>
<body>
  <div class="shell">
    <div class="toolbar">
      <div class="toolbar-group">
        <button id="reload" class="primary">Reload</button>
        <button id="prev">Previous</button>
        <button id="next">Next</button>
      </div>
      <div class="toolbar-group">
        <button id="zoom-out">-</button>
        <button id="fit" class="secondary">Fit Width</button>
        <button id="zoom-in">+</button>
      </div>
      <div class="toolbar-group">
        <button id="single-page" class="secondary">1 Page</button>
        <button id="double-page">2 Pages</button>
      </div>
      <div class="toolbar-group">
        <input id="page-number" type="number" min="1" value="1">
        <span id="page-total">/ 0</span>
      </div>
      <div id="meta" class="meta">Starting viewer...</div>
    </div>
    <div class="stage">
      <div id="empty" class="empty" hidden>
        <h1>LaTeX XDV Viewer</h1>
        <p class="status">Render status appears here while the server prepares your document.</p>
        <p id="empty-detail" class="status"></p>
        <pre id="error" class="error"></pre>
      </div>
      <div id="pages" class="pages" hidden>
        <img id="page-left" class="page" alt="Rendered XDV page" hidden>
        <img id="page-right" class="page" alt="Rendered XDV page" hidden>
      </div>
    </div>
  </div>
  <script>
    const state = {
      payload: null,
      page: 0,
      zoom: 1,
      fitWidth: true,
      spread: 1,
    };

    const pagesNode = document.getElementById("pages");
    const leftPageImage = document.getElementById("page-left");
    const rightPageImage = document.getElementById("page-right");
    const emptyCard = document.getElementById("empty");
    const emptyDetail = document.getElementById("empty-detail");
    const errorBox = document.getElementById("error");
    const meta = document.getElementById("meta");
    const pageNumber = document.getElementById("page-number");
    const pageTotal = document.getElementById("page-total");
    const singlePageButton = document.getElementById("single-page");
    const doublePageButton = document.getElementById("double-page");
    let fallbackPoll = null;

    function clampPage(index) {
      const total = state.payload?.pages?.length || 0;
      if (!total) return 0;
      return Math.max(0, Math.min(index, total - 1));
    }

    function spreadStart(index) {
      if (state.spread === 2) {
        return Math.floor(index / 2) * 2;
      }
      return index;
    }

    function visiblePages() {
      const pages = state.payload?.pages || [];
      const start = spreadStart(state.page);
      if (state.spread === 2) {
        return [pages[start], pages[start + 1] || null];
      }
      return [pages[start], null];
    }

    function applyPageSizing(image, availableWidth) {
      if (!image || image.hidden) return;
      const naturalWidth = image.naturalWidth || 816;
      if (state.fitWidth) {
        image.style.width = `${availableWidth}px`;
      } else {
        image.style.width = `${Math.max(240, Math.round(naturalWidth * state.zoom))}px`;
      }
      image.style.maxWidth = "none";
      image.style.transform = "none";
    }

    function renderPage() {
      const pages = state.payload?.pages || [];
      const total = pages.length;
      pageTotal.textContent = `/ ${total}`;
      pageNumber.value = total ? String(spreadStart(state.page) + 1) : "1";

      if (!total) {
        pagesNode.hidden = true;
        emptyCard.hidden = false;
        emptyDetail.textContent = state.payload?.status || "No pages rendered yet.";
        errorBox.textContent = state.payload?.error || "";
        return;
      }

      const [leftSrc, rightSrc] = visiblePages();
      emptyCard.hidden = true;
      pagesNode.hidden = false;

      if (leftSrc) {
        leftPageImage.hidden = false;
        if (leftPageImage.src !== leftSrc) {
          leftPageImage.src = leftSrc;
        }
      }

      if (rightSrc) {
        rightPageImage.hidden = false;
        if (rightPageImage.src !== rightSrc) {
          rightPageImage.src = rightSrc;
        }
      } else {
        rightPageImage.hidden = true;
        rightPageImage.removeAttribute("src");
      }

      const pageCount = rightSrc ? 2 : 1;
      const availableWidth = Math.max(240, Math.floor((window.innerWidth - 48 - (pageCount - 1) * 20) / pageCount));
      applyPageSizing(leftPageImage, availableWidth);
      applyPageSizing(rightPageImage, availableWidth);

      singlePageButton.classList.toggle("secondary", state.spread === 1);
      doublePageButton.classList.toggle("secondary", state.spread === 2);

      const shown = rightSrc
        ? `pages ${spreadStart(state.page) + 1}-${Math.min(spreadStart(state.page) + 2, total)}`
        : `page ${spreadStart(state.page) + 1}`;
      meta.textContent = `${state.payload.file_name} | ${shown}/${total} | ${Math.round(state.zoom * 100)}%`;
    }

    function refreshState(preservePage = true) {
      fetch("/api/state", { cache: "no-store" })
        .then((response) => response.json())
        .then((payload) => {
          const previousVersion = state.payload?.version;
          state.payload = payload;
          if (!preservePage || previousVersion !== payload.version) {
            state.page = clampPage(state.page);
          }
          meta.textContent = payload.status;
          renderPage();
        })
        .catch((error) => {
          emptyCard.hidden = false;
          pageImage.hidden = true;
          emptyDetail.textContent = "The viewer could not reach the local server.";
          errorBox.textContent = String(error);
        });
    }

    function startFallbackPolling() {
      if (fallbackPoll !== null) return;
      fallbackPoll = window.setInterval(refreshState, 1000);
    }

    function connectEvents() {
      const source = new EventSource("/events");
      source.addEventListener("render", () => refreshState());
      source.addEventListener("status", () => refreshState());
      source.onerror = () => {
        source.close();
        startFallbackPolling();
        window.setTimeout(connectEvents, 1500);
      };
    }

    document.getElementById("reload").addEventListener("click", () => {
      fetch("/api/reload", { method: "POST" }).then(() => refreshState(false));
    });
    document.getElementById("prev").addEventListener("click", () => {
      state.page = clampPage(spreadStart(state.page) - state.spread);
      renderPage();
    });
    document.getElementById("next").addEventListener("click", () => {
      state.page = clampPage(spreadStart(state.page) + state.spread);
      renderPage();
    });
    document.getElementById("zoom-in").addEventListener("click", () => {
      state.fitWidth = false;
      state.zoom = Math.min(state.zoom * 1.2, 6);
      renderPage();
    });
    document.getElementById("zoom-out").addEventListener("click", () => {
      state.fitWidth = false;
      state.zoom = Math.max(state.zoom / 1.2, 0.25);
      renderPage();
    });
    document.getElementById("fit").addEventListener("click", () => {
      state.fitWidth = true;
      state.zoom = 1;
      renderPage();
    });
    singlePageButton.addEventListener("click", () => {
      state.spread = 1;
      state.page = clampPage(spreadStart(state.page));
      renderPage();
    });
    doublePageButton.addEventListener("click", () => {
      state.spread = 2;
      state.page = clampPage(spreadStart(state.page));
      renderPage();
    });
    pageNumber.addEventListener("change", () => {
      state.page = clampPage(spreadStart(Number(pageNumber.value) - 1));
      renderPage();
    });

    leftPageImage.addEventListener("load", () => {
      renderPage();
    });
    rightPageImage.addEventListener("load", () => {
      renderPage();
    });

    window.addEventListener("resize", () => {
      if (state.fitWidth) {
        renderPage();
      }
    });

    window.addEventListener("keydown", (event) => {
      if (event.key === "ArrowRight" || event.key === "ArrowDown") {
        state.page = clampPage(spreadStart(state.page) + state.spread);
        renderPage();
      } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
        state.page = clampPage(spreadStart(state.page) - state.spread);
        renderPage();
      } else if (event.key === "+" || event.key === "=") {
        state.fitWidth = false;
        state.zoom = Math.min(state.zoom * 1.2, 6);
        renderPage();
      } else if (event.key === "-") {
        state.fitWidth = false;
        state.zoom = Math.max(state.zoom / 1.2, 0.25);
        renderPage();
      } else if (event.key === "0") {
        state.fitWidth = true;
        state.zoom = 1;
        renderPage();
      } else if (event.key.toLowerCase() === "r") {
        fetch("/api/reload", { method: "POST" }).then(() => refreshState(false));
      } else if (event.key === "1") {
        state.spread = 1;
        state.page = clampPage(spreadStart(state.page));
        renderPage();
      } else if (event.key === "2") {
        state.spread = 2;
        state.page = clampPage(spreadStart(state.page));
        renderPage();
      }
    });

    refreshState(false);
    connectEvents();
  </script>
</body>
</html>
"""


class ViewerState:
    def __init__(self, input_path: Path) -> None:
        self.input_path = input_path.resolve()
        self.input_kind = self._detect_input_kind(self.input_path)
        self.output_root = Path(tempfile.mkdtemp(prefix="xdv-viewer-"))
        self.lock = threading.Lock()
        self.listeners: set[queue.Queue[str]] = set()
        self.version = 0
        self.status = "Waiting for first render..."
        self.error = ""
        self.file_name = self.input_path.name
        self.page_paths: list[Path] = []
        self.last_mtime: float | None = None

    def cleanup(self) -> None:
        shutil.rmtree(self.output_root, ignore_errors=True)

    @staticmethod
    def _detect_input_kind(input_path: Path) -> str:
        suffix = input_path.suffix.lower()
        if suffix == ".tex":
            return "tex"
        if suffix == ".xdv":
            return "xdv"
        raise ValueError("Input must be a .tex or .xdv file")

    def source_label(self) -> str:
        if self.input_kind == "tex":
            return f"{self.input_path.name} -> {self.input_path.with_suffix('.xdv').name}"
        return self.input_path.name

    def xdv_path(self) -> Path:
        if self.input_kind == "tex":
            return self.input_path.with_suffix(".xdv")
        return self.input_path

    def _compile_tex_to_xdv(self) -> Path:
        if shutil.which("latexmk") is None:
            raise RuntimeError("Missing required tool: latexmk")

        xdv_path = self.input_path.with_suffix(".xdv")
        previous_mtime = xdv_path.stat().st_mtime if xdv_path.exists() else None

        compile_run = subprocess.run(
            [
                "latexmk",
                "-xelatex",
                "-e",
                "$xelatex=q/xelatex -no-pdf %O %S/; $xdvipdfmx=q/true/;",
                self.input_path.name,
            ],
            capture_output=True,
            text=True,
            check=False,
            cwd=self.input_path.parent,
        )
        if compile_run.returncode != 0:
            combined_output = compile_run.stdout + compile_run.stderr
            fresh_xdv = (
                xdv_path.exists()
                and (
                    previous_mtime is None
                    or xdv_path.stat().st_mtime > previous_mtime
                )
            )
            if xdv_path.exists() and "xdvipdfmx: failed to create output file" in combined_output:
                return xdv_path
            stderr = compile_run.stderr.strip()
            stdout = compile_run.stdout.strip()
            details = stderr or stdout
            raise RuntimeError(f"latexmk failed:\n{details}")

        if not xdv_path.exists():
            raise RuntimeError(f"latexmk did not produce {xdv_path.name}")
        return xdv_path

    def render(self) -> None:
        if not self.input_path.exists():
            with self.lock:
                self.status = f"Missing source file: {self.input_path}"
                self.error = ""
                self.page_paths = []
            return

        if shutil.which("dvisvgm") is None:
            raise RuntimeError("Missing required tool: dvisvgm")

        xdv_path = self._compile_tex_to_xdv() if self.input_kind == "tex" else self.xdv_path()
        if not xdv_path.exists():
            raise RuntimeError(f"Missing XDV file: {xdv_path}")

        safe_stem = "".join(
            character if character.isalnum() or character in {"-", "_"} else "_"
            for character in xdv_path.stem
        ).strip("_") or "document"

        version = int(time.time() * 1000)
        work_dir = self.output_root / f"{safe_stem}-{version}"
        work_dir.mkdir(parents=True, exist_ok=True)

        conversion = subprocess.run(
            [
                "dvisvgm",
                "--page=1-",
                "--no-fonts",
                "--output=page-%p.svg",
                str(xdv_path),
            ],
            capture_output=True,
            text=True,
            check=False,
            cwd=work_dir,
        )
        if conversion.returncode != 0:
            stderr = conversion.stderr.strip() or conversion.stdout.strip()
            raise RuntimeError(f"dvisvgm failed:\n{stderr}")

        page_paths = sorted(work_dir.glob("page-*.svg"))
        if not page_paths:
            raise RuntimeError("No SVG pages were generated.")

        with self.lock:
            self.version = version
            self.page_paths = page_paths
            self.last_mtime = self.input_path.stat().st_mtime
            self.file_name = self.source_label()
            self.status = f"Rendered {len(page_paths)} page(s) from {self.source_label()}"
            self.error = ""
        self.notify("render")

    def snapshot(self) -> dict[str, object]:
        with self.lock:
            pages = [f"/pages/{self.version}/{path.name}" for path in self.page_paths]
            return {
                "file_name": self.file_name,
                "status": self.status,
                "error": self.error,
                "version": self.version,
                "pages": pages,
            }

    def page_file(self, version: str, name: str) -> Path | None:
        with self.lock:
            if str(self.version) != version:
                return None
            for path in self.page_paths:
                if path.name == name:
                    return path
        return None

    def add_listener(self) -> queue.Queue[str]:
        listener: queue.Queue[str] = queue.Queue()
        with self.lock:
            self.listeners.add(listener)
        return listener

    def remove_listener(self, listener: queue.Queue[str]) -> None:
        with self.lock:
            self.listeners.discard(listener)

    def notify(self, event: str) -> None:
        with self.lock:
            listeners = list(self.listeners)
        for listener in listeners:
            listener.put(event)


def make_handler(state: ViewerState):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/":
                self._send_html()
            elif parsed.path == "/api/state":
                self._send_json(state.snapshot())
            elif parsed.path == "/events":
                self._send_events()
            elif parsed.path.startswith("/pages/"):
                self._send_page(parsed.path)
            else:
                self.send_error(HTTPStatus.NOT_FOUND)

        def do_HEAD(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path.startswith("/pages/"):
                self._send_page(parsed.path, head_only=True)
            else:
                self.send_error(HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/api/reload":
                try:
                    state.render()
                    self._send_json(state.snapshot())
                except Exception as exc:
                    with state.lock:
                        state.status = "Manual reload failed."
                        state.error = str(exc)
                    state.notify("status")
                    self._send_json(state.snapshot(), status=HTTPStatus.INTERNAL_SERVER_ERROR)
            else:
                self.send_error(HTTPStatus.NOT_FOUND)

        def log_message(self, format: str, *args) -> None:
            return

        def _send_html(self) -> None:
            body = HTML.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_json(self, payload: dict[str, object], status: HTTPStatus = HTTPStatus.OK) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _send_events(self) -> None:
            listener = state.add_listener()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                self.wfile.write(b"retry: 1500\n\n")
                self.wfile.flush()
                while True:
                    try:
                        event = listener.get(timeout=15.0)
                        payload = f"event: {event}\ndata: {state.version}\n\n".encode("utf-8")
                    except queue.Empty:
                        payload = b": keepalive\n\n"
                    self.wfile.write(payload)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                state.remove_listener(listener)

        def _send_page(self, path: str, head_only: bool = False) -> None:
            parts = path.strip("/").split("/")
            if len(parts) != 3:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            _, version, name = parts
            page = state.page_file(version, name)
            if page is None or not page.exists():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            body = page.read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "image/svg+xml")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if not head_only:
                self.wfile.write(body)

    return Handler


def watch_for_changes(state: ViewerState, stop_event: threading.Event) -> None:
    pending_mtime: float | None = None
    dirty_since: float | None = None

    while not stop_event.wait(SOURCE_POLL_INTERVAL):
        if not state.input_path.exists():
            continue

        current_mtime = state.input_path.stat().st_mtime
        rendered_mtime = state.last_mtime
        now = time.monotonic()

        if rendered_mtime is None or current_mtime > rendered_mtime:
            if pending_mtime is None or current_mtime > pending_mtime:
                pending_mtime = current_mtime
                dirty_since = now

        if pending_mtime is None or dirty_since is None:
            continue

        if now - dirty_since < SOURCE_SETTLE_DELAY:
            continue

        try:
            state.render()
        except Exception as exc:
            with state.lock:
                state.status = "Automatic reload failed."
                state.error = str(exc)
            state.notify("status")
        finally:
            pending_mtime = None
            dirty_since = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve a local XDV viewer in your browser.")
    parser.add_argument("input", type=Path, help="Path to the .tex or .xdv file to view")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind the local server to")
    parser.add_argument("--port", type=int, default=0, help="Port to bind the local server to")
    parser.add_argument(
        "--no-open",
        action="store_true",
        help="Do not automatically open the viewer in the default browser",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    state = ViewerState(args.input)

    try:
        state.render()
    except Exception as exc:
        with state.lock:
            state.status = "Initial render failed."
            state.error = str(exc)

    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    host, port = server.server_address[:2]
    url = f"http://{host}:{port}/"

    stop_event = threading.Event()
    watcher = threading.Thread(target=watch_for_changes, args=(state, stop_event), daemon=True)
    watcher.start()

    print(f"Serving {state.input_path} at {url}")
    if not args.no_open:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping viewer...")
    finally:
        stop_event.set()
        server.server_close()
        state.cleanup()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
