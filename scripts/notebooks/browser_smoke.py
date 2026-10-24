"""Browser acceptance for actual R widget output from scripts.notebooks.smoke.

Run with Playwright installed: python -m scripts.notebooks.browser_smoke OUTPUT_DIR
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread


def validate(directory):
    from playwright.sync_api import sync_playwright, expect
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(directory)))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            context = browser.new_context()
            base = f"http://127.0.0.1:{server.server_port}"
            context.route("**/*", lambda route: route.continue_()
                          if route.request.url.startswith(base + "/") else route.abort())
            page = context.new_page()
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.goto(base + "/index.html")
            frames = page.locator("iframe[srcdoc]")
            assert frames.count() == 3, "Expected DT, Plotly and visNetwork frames"
            table = frames.nth(0).content_frame
            table.locator("table.dataTable").wait_for()
            search = table.locator('input[type="search"]')
            search.fill("B")
            expect(table.locator("tbody tr")).to_have_count(1)
            expect(table.locator("tbody")).to_contain_text("B")
            search.fill("")
            expect(table.locator("tbody tr")).to_have_count(2)
            value_header = table.locator("thead th").filter(has_text="value")
            value_header.click()
            expect(value_header).to_have_attribute("aria-sort", "ascending")
            value_header.click()
            expect(value_header).to_have_attribute("aria-sort", "descending")
            expect(table.locator("tbody tr").first).to_contain_text("B")
            plot = frames.nth(1).content_frame
            plot.locator(".js-plotly-plot .main-svg").first.wait_for()
            assert plot.locator(".js-plotly-plot").evaluate("el => el._fullLayout.xaxis.rangeslider.visible")
            before = plot.locator(".js-plotly-plot").evaluate("el => el._fullLayout.xaxis.range.slice()")
            plot.locator('[data-title="Zoom in"]').click()
            after = plot.locator(".js-plotly-plot").evaluate("el => el._fullLayout.xaxis.range.slice()")
            assert before != after, "Plotly zoom did not change the axis range"
            graph = frames.nth(2).content_frame
            graph.locator("canvas").wait_for()
            assert not errors, errors
            browser.close()
    finally:
        server.shutdown()
        server.server_close()
    print("Browser acceptance passed: DT filtering, Plotly zoom and network canvas")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    validate(parser.parse_args().directory.resolve())
