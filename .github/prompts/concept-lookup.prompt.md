---
description: "Look up OMOP standard concept IDs in the live cdm_synthea vocabulary. Use before writing any concept_id into code or CSV files. Accepts a clinical term and optional domain (condition, drug, procedure, measurement, observation, visit)."
name: "OMOP Concept Lookup"
argument-hint: "<clinical term> [domain]"
agent: "agent"
tools: ["mssql_connect", "mssql_run_query", "mssql_disconnect", "mssql_get_connection_details"]
---

You are performing an OMOP vocabulary lookup against the live `omop_synth` database.

## Connection

Connect using these parameters — do not prompt the user for credentials:
- Server: `localhost,1434`
- Database: `omop_synth`
- Use Windows authentication (trust server certificate)

If already connected, skip the connect step.

## Input

The user has provided: **${{input}}**

Parse this as:
- **term**: the clinical concept to search for (required)
- **domain**: optional filter — one of `Condition`, `Drug`, `Procedure`, `Measurement`,
  `Observation`, `Visit`. If not provided, search all domains.

## Queries to Run

### 1. Direct name match (primary)

```sql
SELECT TOP 20
    concept_id,
    concept_name,
    domain_id,
    vocabulary_id,
    concept_class_id,
    standard_concept,
    concept_code
FROM cdm_synthea.concept
WHERE standard_concept = 'S'
  AND invalid_reason IS NULL
  AND LOWER(concept_name) LIKE LOWER('%<term>%')
  -- add: AND domain_id = '<domain>'  when domain is specified
ORDER BY
    CASE WHEN LOWER(concept_name) = LOWER('<term>') THEN 0 ELSE 1 END,
    LEN(concept_name),
    concept_name
```

### 2. Synonym / fuzzy match (run only if query 1 returns fewer than 3 results)

```sql
SELECT TOP 10
    c.concept_id,
    c.concept_name,
    c.domain_id,
    c.vocabulary_id,
    c.concept_class_id,
    cs.concept_synonym_name AS matched_synonym
FROM cdm_synthea.concept c
JOIN cdm_synthea.concept_synonym cs ON c.concept_id = cs.concept_id
WHERE c.standard_concept = 'S'
  AND c.invalid_reason IS NULL
  AND LOWER(cs.concept_synonym_name) LIKE LOWER('%<term>%')
  -- add: AND c.domain_id = '<domain>'  when domain is specified
ORDER BY LEN(cs.concept_synonym_name), c.concept_name
```

Substitute `<term>` with the actual search term and, when domain is given, uncomment
the `AND domain_id` filter in each query.

## Output Format

Present results as a Markdown table with these columns:

| concept_id | concept_name | domain_id | vocabulary_id | concept_class_id |
|------------|-------------|-----------|---------------|-----------------|
| ...        | ...         | ...       | ...           | ...             |

After the table, provide a **Recommended concept_id** — the single best match — with
a one-sentence rationale (e.g., most specific standard concept, preferred vocabulary
for this domain).

If no standard concepts are found, state that clearly and suggest alternative search
terms or vocabulary (e.g., "Try searching for the ingredient name rather than the
brand name").

## Disconnect

Disconnect from the database after all queries are complete.
