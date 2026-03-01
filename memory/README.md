# Memory System

The memory directory stores all persistent data that agents and the evolution system use to learn and improve over time.

## Directory Structure

```
memory/
├── schemas/                     # JSON schemas for data validation
│   ├── trajectory-pool.schema.json
│   └── evolution-log.schema.json
├── examples/                    # Example data files
│   ├── trajectory-pool.json
│   ├── evolution-log.md
│   └── reflection-example.md
├── trajectory-pool.json         # Active task records (max 100)
├── trajectory-archive/          # Monthly archives
│   └── YYYY-MM.json
├── reflections/                 # Agent self-reflections
│   └── <agent-name>/
│       └── YYYY-MM-DD-<title>.md
├── knowledge/                   # Research findings
│   └── YYYY-MM-DD-<topic>.md
├── predictions/                 # Prediction reports
│   └── YYYY-MM-DD-<mode>.md
├── briefings/                   # Status reports
│   └── YYYY-MM-DD-<phase>.md
├── goals/                       # Goal tracking
│   └── active-goals.json
├── evolution-log.md             # Change history
├── metrics.db                   # SQLite metrics (created by metrics.sh)
└── skill-registry.json          # Skill tracking (created by skill-discovery.sh)
```

## Key Concepts

- **Trajectory Pool**: Records of every task outcome — the raw data for evolution
- **Reflections**: Post-failure self-evaluations that prevent repeated mistakes
- **Evolution Log**: History of all changes made through the evolution cycle
- **Knowledge Base**: Research findings accumulated over time

## Size Management

- Trajectory pool: max 100 active records. Older records archived monthly.
- Success records: 4-week active retention
- Failure records: 8-week active retention (longer for pattern analysis)
- Reflections: kept indefinitely (small files, high value)

## Data Security

Memory files should NEVER contain:
- API keys, tokens, or passwords
- Raw user data or personal information
- Full API responses
- Webhook URLs or internal endpoints

See `schemas/` for data validation and `examples/` for reference data.
