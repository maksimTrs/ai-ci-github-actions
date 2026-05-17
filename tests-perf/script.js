import http from "k6/http";
import { sleep, check } from "k6";
import { htmlReport } from "./lib/k6-reporter.js";
import { textSummary } from "./lib/k6-summary.js";

export const options = {
  duration: "30s",
  vus: 1,
  thresholds: {
    http_req_failed: ["rate<0.01"], // http errors should be less than 1%
    http_req_duration: ["p(95)<500"], // 95 percent of response times must be below 500ms
  },
};

export default function () {
  // Health check
  const healthRes = http.get("http://localhost:8080/api/health");
  check(healthRes, {
    "health check status is 200": (r) => r.status === 200,
  });

  // Create a new bug
  const payload = JSON.stringify({
    title: `Test Bug ${Date.now()}`,
    description: "This is a test bug created by k6",
    priority: "Medium",
    status: "Open",
  });

  const headers = { "Content-Type": "application/json" };

  const createBugRes = http.post("http://localhost:8080/api/bugs", payload, {
    headers,
  });

  check(createBugRes, {
    "create bug status is 201": (r) => r.status === 201,
    "bug has an id": (r) => JSON.parse(r.body).id !== undefined,
  });

  sleep(5);
}

function escapeXml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

// Minimal JUnit XML writer for k6 threshold results.
// Emits one <testcase> per (metric, threshold) pair; failed thresholds get a <failure>.
function junitXml(data) {
  const cases = [];
  let failures = 0;
  let total = 0;

  const metrics = data.metrics || {};
  for (const metricName of Object.keys(metrics)) {
    const metric = metrics[metricName];
    if (!metric.thresholds) continue;
    for (const thrName of Object.keys(metric.thresholds)) {
      const thr = metric.thresholds[thrName];
      total++;
      const caseName = escapeXml(`${metricName}: ${thrName}`);
      if (thr.ok) {
        cases.push(`    <testcase name="${caseName}" classname="k6.thresholds"/>`);
      } else {
        failures++;
        cases.push(
          `    <testcase name="${caseName}" classname="k6.thresholds">\n` +
          `      <failure message="threshold breached">${caseName}</failure>\n` +
          `    </testcase>`
        );
      }
    }
  }

  return `<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="k6" tests="${total}" failures="${failures}">
${cases.join("\n")}
  </testsuite>
</testsuites>
`;
}

export function handleSummary(data) {
  return {
    "reports/perf-results.html": htmlReport(data),
    "test-results/results.xml": junitXml(data),
    stdout: textSummary(data, { indent: " ", enableColors: true }),
  };
}
