// Runs the engine with the Chromium that ships inside a serverless function (@sparticuz/chromium) rather
// than a Playwright-managed download. Loaded lazily so the unit tests never need either.
import chromium from "@sparticuz/chromium";
import { chromium as playwright } from "playwright-core";
import { runBrowserScan } from "./engine.mjs";

export async function runHosted(args) {
  const launch = async () => playwright.launch({
    headless: true,
    args: chromium.args,
    executablePath: await chromium.executablePath(),
  });
  return runBrowserScan({ ...args, deps: { ...(args.deps ?? {}), launch } });
}
