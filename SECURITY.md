# Security Policy

## Reporting a vulnerability

Please report vulnerabilities through GitHub's private vulnerability reporting feature rather
than a public issue. Include reproduction steps, affected components, and any suggested mitigation.

Do not include credentials, Terraform state, access tokens, subscription or tenant identifiers, or
other sensitive deployment data in an issue or pull request.

## Supported versions

This lab tracks the default branch only. Security fixes are not backported to earlier revisions.

## Authentication posture

Foundry, AI Search, Storage, and Cosmos DB are configured without local or shared-key data-plane
authentication. Workloads use managed identities, Entra ID tokens, and scoped Azure RBAC. Do not
replace these paths with connection strings or API keys in examples or contributions.

The Windows jumpbox retains a generated local administrator password for Bastion RDP. Terraform
marks the output sensitive, but the value remains in local state. Protect the state file and retrieve
the password only when interactive access is required.

The SharePoint integration requires application permissions such as `Sites.Selected`; grant the
narrowest site scope possible and never commit tenant-specific consent artifacts.