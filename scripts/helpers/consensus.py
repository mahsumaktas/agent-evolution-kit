#!/usr/bin/env python3
# Part of Agent Evolution Kit — https://github.com/mahsumaktas/agent-evolution-kit
#
# consensus.py — Standalone voting aggregator.
#
# Usage:
#   echo '[{"agent":"a","vote":"APPROVE"},...]' | python3 consensus.py --type majority
#   python3 consensus.py --type weighted --file votes.json
#
# Voting types:
#   majority      — >50% for one option
#   supermajority — >66.7% for one option
#   unanimous     — 100% agreement
#   weighted      — sum weights per option (vote.weight, default 1.0)
#   quorum        — min N participants + majority among them

import argparse
import json
import sys
from collections import Counter


def parse_votes(raw_votes):
    """Parse vote list, return list of dicts with agent/vote/weight."""
    votes = []
    for v in raw_votes:
        votes.append({
            "agent": v.get("agent", "unknown"),
            "vote": v.get("vote", "ABSTAIN"),
            "weight": float(v.get("weight", 1.0)),
        })
    return votes


def count_votes(votes):
    """Count votes by option."""
    counter = Counter()
    for v in votes:
        counter[v["vote"]] += 1
    return dict(counter)


def decide_majority(votes, threshold=0.5):
    """Return winner if any option exceeds threshold fraction."""
    total = len(votes)
    if total == 0:
        return None, False, {}, 0.0

    vote_counts = count_votes(votes)
    best_option = max(vote_counts, key=vote_counts.get)
    best_count = vote_counts[best_option]
    margin = best_count / total

    if margin > threshold:
        return best_option, True, vote_counts, round(margin, 3)
    return None, False, vote_counts, round(margin, 3)


def decide_supermajority(votes):
    """Supermajority: >66.7%."""
    return decide_majority(votes, threshold=2.0 / 3.0)


def decide_unanimous(votes):
    """All votes must be the same."""
    total = len(votes)
    if total == 0:
        return None, False, {}, 0.0

    vote_counts = count_votes(votes)
    if len(vote_counts) == 1:
        option = list(vote_counts.keys())[0]
        return option, True, vote_counts, 1.0
    return None, False, vote_counts, 0.0


def decide_weighted(votes):
    """Sum weights per option, highest wins if > 50% of total weight."""
    total_weight = sum(v["weight"] for v in votes)
    if total_weight == 0:
        return None, False, {}, 0.0

    weight_sums = {}
    vote_counts = count_votes(votes)
    for v in votes:
        weight_sums[v["vote"]] = weight_sums.get(v["vote"], 0.0) + v["weight"]

    best_option = max(weight_sums, key=weight_sums.get)
    best_weight = weight_sums[best_option]
    margin = best_weight / total_weight

    if margin > 0.5:
        return best_option, True, vote_counts, round(margin, 3)
    return None, False, vote_counts, round(margin, 3)


def decide_quorum(votes, quorum_min=None):
    """Min N participants required, then majority among them."""
    total = len(votes)
    if quorum_min is None:
        quorum_min = max(1, (total + 1) // 2)

    if total < quorum_min:
        vote_counts = count_votes(votes)
        return None, False, vote_counts, 0.0

    return decide_majority(votes)


def run_consensus(votes, consensus_type, quorum_min=None):
    """Run the appropriate consensus algorithm."""
    if consensus_type == "majority":
        result, decided, vote_counts, margin = decide_majority(votes)
    elif consensus_type == "supermajority":
        result, decided, vote_counts, margin = decide_supermajority(votes)
    elif consensus_type == "unanimous":
        result, decided, vote_counts, margin = decide_unanimous(votes)
    elif consensus_type == "weighted":
        result, decided, vote_counts, margin = decide_weighted(votes)
    elif consensus_type == "quorum":
        result, decided, vote_counts, margin = decide_quorum(votes, quorum_min)
    else:
        print(f"Unknown consensus type: {consensus_type}", file=sys.stderr)
        sys.exit(1)

    return {
        "result": result,
        "decided": decided,
        "consensus_type": consensus_type,
        "total_votes": len(votes),
        "vote_counts": vote_counts,
        "margin": margin,
    }


def main():
    parser = argparse.ArgumentParser(description="Consensus voting engine")
    parser.add_argument(
        "--type",
        required=True,
        choices=["majority", "supermajority", "unanimous", "weighted", "quorum"],
        help="Consensus type",
    )
    parser.add_argument(
        "--file",
        default=None,
        help="JSON file with votes (default: read from stdin)",
    )
    parser.add_argument(
        "--quorum-min",
        type=int,
        default=None,
        help="Minimum participants for quorum type (default: half of total)",
    )

    args = parser.parse_args()

    # Read votes
    if args.file:
        with open(args.file, "r") as f:
            raw_votes = json.load(f)
    else:
        raw_input = sys.stdin.read().strip()
        if not raw_input:
            raw_votes = []
        else:
            raw_votes = json.loads(raw_input)

    if not isinstance(raw_votes, list):
        print("Error: votes must be a JSON array", file=sys.stderr)
        sys.exit(1)

    votes = parse_votes(raw_votes)
    output = run_consensus(votes, args.type, args.quorum_min)

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
