# Accelerator Guide

Start at the [repository overview](../README.md) for the document-to-answer journey
and the four-stage deployment entrypoint. This directory separates repeatable
instructions from dated implementation and acceptance history.

## Choose your task

| I want to... | Start here |
| --- | --- |
| Understand the services, identities and data flow | [Architecture](architecture.md) |
| Deploy a new private environment | [Deployment](deployment.md) |
| Install development tools and run checks without Azure | [Testing](TESTING.md) |
| Ingest the fixture and ask a grounded question | [Complete demo](deployment.md#complete-demo) and [Python client](../src/hello_world/README.md) |
| Connect a real SharePoint document | [Site-scoped setup](deployment.md#optional-sharepoint) |
| Add sources, vectors, tools, throughput or resilience | [Extension playbooks](architecture.md#extension-playbooks) |
| Diagnose, pause, recover or remove an environment | [Operations](operations.md) |
| Understand CI, private runners and deployment approvals | [Automation](automation.md) |
| Check dependency, API and runtime assumptions | [Compatibility](compatibility.md) |
| Change code or report an issue | [Contributing](../CONTRIBUTING.md) and [security policy](../SECURITY.md) |

## Design assets

- [Topology PNG](diagrams/capability-host-deployment-azure-architecture.png) and
  [Mermaid source](diagrams/capability-host-deployment-azure-architecture.mmd).
- [Runtime PNG](diagrams/runtime-flow-azure-architecture.png) and
  [Mermaid source](diagrams/runtime-flow-azure-architecture.mmd).
- [Diagram reproduction and review contract](diagrams/README.md).

## Status and evidence

[STATUS.md](STATUS.md) records the current accepted baseline and clearly labeled
historical migrations. [VALIDATION.md](VALIDATION.md) records live checks, hosted CI,
recovery boundaries and scenarios not run. Neither authorizes work on another
subscription or proves that another environment is ready.

[ACCELERATOR-PLAN.md](ACCELERATOR-PLAN.md) and [PLAN.md](PLAN.md) preserve implementation
history. They are not the deployment walkthrough or the active backlog; current
work is tracked in Beads. Use the guides above for new deployments.