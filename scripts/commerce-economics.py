#!/usr/bin/env python3
"""Unmetered relay liability sensitivity. No production usage or FX is inferred."""
import argparse
import csv
import math
import sys
from dataclasses import dataclass

# Verified 2026-09-30: https://developers.cloudflare.com/realtime/turn/faq/
TURN_USD_PER_GB = 0.05

@dataclass(frozen=True)
class Scenario:
    charged_mbps: float  # aggregate provider-charged egress, includes overhead
    hours_per_month: float
    relay_fraction: float
    support_usd_per_month: float = 0.0  # zero is an explicit exclusion, not verified cost

    def monthly_cost(self):
        fields = (self.charged_mbps, self.hours_per_month, self.relay_fraction, self.support_usd_per_month)
        if not all(math.isfinite(x) and x >= 0 for x in fields) or self.relay_fraction > 1:
            raise ValueError("Finite nonnegative usage and relay fraction 0...1 required")
        return self.charged_mbps * 0.45 * self.hours_per_month * self.relay_fraction * TURN_USD_PER_GB + self.support_usd_per_month

def net_usd(price_cad, cad_per_usd, commission):
    if not all(math.isfinite(x) for x in (price_cad, cad_per_usd, commission)) or price_cad < 0 or cad_per_usd <= 0 or not 0 <= commission < 1:
        raise ValueError("Positive scenario FX and commission 0..<1 required")
    return price_cad / cad_per_usd * (1 - commission)

def tail_cost(monthly, years, discount=0, growth=0):
    if years < 0 or not math.isfinite(monthly) or monthly < 0 or discount < 0 or growth < 0:
        raise ValueError("Nonnegative finite cost and horizon required")
    return sum(monthly * 12 * ((1 + growth) / (1 + discount)) ** year for year in range(1, years + 1))

def perpetual_tail(monthly, discount=0, growth=0):
    if monthly == 0: return 0.0
    if discount <= growth: return math.inf
    return monthly * 12 * (1 + growth) / (discount - growth)

def rows(cad_per_usd, commission):
    # Workload inputs are sensitivity scenarios, never measured product facts.
    for name, scenario in [('light', Scenario(4, 4, .2)), ('regular', Scenario(8, 20, .5)), ('heavy', Scenario(16, 80, 1))]:
        cost = scenario.monthly_cost()
        yield dict(scenario=name, cost_usd_month=round(cost, 3), monthly_net_usd=round(net_usd(7.99, cad_per_usd, commission), 3),
                   annual_net_usd_month=round(net_usd(59.99, cad_per_usd, commission) / 12, 3),
                   lifetime_10y_usd=round(tail_cost(cost, 10), 2), lifetime_20y_usd=round(tail_cost(cost, 20), 2),
                   lifetime_40y_usd=round(tail_cost(cost, 40), 2), lifetime_perpetual_undiscounted='unbounded' if cost > 0 else 0,
                   lifetime_perpetual_5pct_usd=round(perpetual_tail(cost, .05), 2),
                   lifetime_199cad_net_usd=round(net_usd(199, cad_per_usd, commission), 2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cad-per-usd', type=float, required=True, help='Scenario FX, NOT a live exchange quote')
    parser.add_argument('--commission', type=float, choices=[.15, .30], required=True, help='Scenario only; program enrollment not established')
    args = parser.parse_args()
    output = list(rows(args.cad_per_usd, args.commission))
    writer = csv.DictWriter(sys.stdout, fieldnames=output[0].keys()); writer.writeheader(); writer.writerows(output)
