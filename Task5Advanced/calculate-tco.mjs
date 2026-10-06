import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const usage = 'Usage: node calculate-tco.mjs [inputs.json]\nCalculate draft three-year TCO in million RUB; no network or file writes.';
if (args.length === 1 && ['--help', '-h'].includes(args[0])) {
  console.log(usage);
  process.exit(0);
}

const fail = (message) => { throw new Error(message); };
const sum = (values) => values.reduce((total, value) => total + value, 0);
const round = (value) => Math.round((value + Number.EPSILON) * 100) / 100;
const nonnegative = (value, name) => {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    fail(`${name} must be a finite nonnegative number`);
  }
};
const vector = (values, name) => {
  if (!Array.isArray(values) || values.length !== 3) fail(`${name} must contain three years`);
  values.forEach((value, index) => nonnegative(value, `${name}[${index}]`));
};
const costRows = (rows, required, name) => {
  if (!rows || typeof rows !== 'object' || Array.isArray(rows)) fail(`${name} must be an object`);
  if (Object.keys(rows).sort().join(',') !== required.sort().join(',')) fail(`Unexpected cost categories in ${name}`);
  Object.entries(rows).forEach(([key, values]) => vector(values, `${name}.${key}`));
};
const annual = (rows) => [0, 1, 2].map((year) => sum(Object.values(rows).map((values) => values[year])));

try {
  if (args.length > 1 || args[0]?.startsWith('-')) fail(usage);
  const path = args[0] ?? fileURLToPath(new URL('./tco-inputs.json', import.meta.url));
  const input = JSON.parse(readFileSync(path, 'utf8'));
  if (input.years !== 3 || input.unit !== 'million_RUB_2026') fail('Expected three years in million_RUB_2026');
  nonnegative(input.analyst_hourly_rub, 'analyst_hourly_rub');
  vector(input.current_analyst_hours, 'current_analyst_hours');
  vector(input.target_analyst_hours, 'target_analyst_hours');
  costRows(input.current, ['legacy_infrastructure', 'licenses', 'operations'], 'current');
  costRows(input.target, ['cloud_infrastructure', 'legacy_infrastructure', 'licenses', 'operations', 'migration', 'training'], 'target');
  const sensitivity = input.sensitivity;
  if (!sensitivity || typeof sensitivity !== 'object') fail('Missing sensitivity assumptions');
  nonnegative(sensitivity.cloud_multiplier, 'cloud_multiplier');
  nonnegative(sensitivity.delay_analyst_hours, 'delay_analyst_hours');
  if (!Number.isInteger(sensitivity.delay_year_index) || sensitivity.delay_year_index < 0 || sensitivity.delay_year_index > 2) {
    fail('delay_year_index must be 0, 1 or 2');
  }
  if (!sensitivity.delay_cost_additions || typeof sensitivity.delay_cost_additions !== 'object' || Array.isArray(sensitivity.delay_cost_additions)) {
    fail('delay_cost_additions must be an object');
  }
  for (const [key, value] of Object.entries(sensitivity.delay_cost_additions)) {
    if (!Object.hasOwn(input.target, key)) fail(`Unknown delay cost category: ${key}`);
    nonnegative(value, `delay_cost_additions.${key}`);
  }

  const analystCosts = (hours) => hours.map((value) => value * input.analyst_hourly_rub / 1_000_000);
  const current = { ...input.current, analyst_time: analystCosts(input.current_analyst_hours) };
  const target = { ...input.target, analyst_time: analystCosts(input.target_analyst_hours) };
  const currentAnnual = annual(current);
  const currentTotal = sum(currentAnnual);
  const summarize = (rows) => {
    const years = annual(rows);
    const differences = years.map((value, year) => currentAnnual[year] - value);
    return {
      annual: years.map(round),
      total: round(sum(years)),
      current_minus_target: round(currentTotal - sum(years)),
      difference_by_year: differences.map(round),
      cumulative_difference: differences.map((_, year) => round(sum(differences.slice(0, year + 1))))
    };
  };
  const costlyCloud = structuredClone(target);
  costlyCloud.cloud_infrastructure = costlyCloud.cloud_infrastructure.map((value) => value * sensitivity.cloud_multiplier);
  const delayed = structuredClone(target);
  for (const [key, value] of Object.entries(sensitivity.delay_cost_additions)) delayed[key][sensitivity.delay_year_index] += value;
  delayed.analyst_time[sensitivity.delay_year_index] += sensitivity.delay_analyst_hours * input.analyst_hourly_rub / 1_000_000;

  console.log(JSON.stringify({
    status: input.status,
    unit: input.unit,
    current: { annual: currentAnnual.map(round), total: round(currentTotal) },
    target: summarize(target),
    excluding_analyst_capacity: {
      current: round(sum(annual(input.current))),
      target: round(sum(annual(input.target)))
    },
    released_analyst_hours: sum(input.current_analyst_hours) - sum(input.target_analyst_hours),
    sensitivity: { cloud_cost_increase: summarize(costlyCloud), delayed_retirement: summarize(delayed) }
  }, null, 2));
} catch (error) {
  console.error(`TCO calculation failed: ${error.message}`);
  process.exitCode = 1;
}
