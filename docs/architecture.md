# Architecture

## Verified data path

```mermaid
flowchart TB
    SPO["SharePoint Online<br/><i>public Graph API</i>"]

    subgraph CUS["Central US — vnet-fwf-cus"]
        JB["Jumpbox<br/>10.10.2.x"]
        BAS["Bastion Standard<br/>10.10.3.0/26"]
        AGENT["snet-agent 172.16.0.0/24<br/>delegated Microsoft.App/environments"]
        subgraph PECUS["snet-pe 10.10.1.0/24"]
            FOUNDRY["Foundry account<br/>network-injected"]
            SEARCH["AI Search S1<br/>semantic ranker"]
            COSMOS["Cosmos 6000 RU/s"]
            STOR["Storage"]
            KV["Key Vault"]
        end
    end

    subgraph HUBS["Virtual WAN Standard"]
        FW1["AzFW — hub CUS<br/>10.100.0.0/23"]
        FW2["AzFW — hub SCUS<br/>10.101.0.0/23"]
    end

    subgraph SCUS["South Central US — vnet-fwf-scus"]
        FUNC["snet-func 10.20.2.0/24<br/>delegated (unused)"]
        subgraph PESCUS["snet-pe 10.20.1.0/24"]
            CU["Content Understanding"]
            STAGE["Staging blob"]
        end
    end

    SPO -.->|"public egress<br/>via firewall"| FW1
    BAS --> JB
    JB --> PECUS
    JB -->|"private, RFC1918"| FW1
    FW1 <-->|"hub-to-hub"| FW2
    FW2 --> PESCUS
    CU -->|"markdown"| SEARCH
    SEARCH -->|"shared private link<br/>groupId openai_account"| FOUNDRY
    FOUNDRY --- AGENT
    SEARCH --- KB["Foundry IQ<br/>knowledge base"]

    classDef pub fill:#8b2020,stroke:#ff6b6b,color:#fff
    classDef priv fill:#1f3a5f,stroke:#4a9eff,color:#fff
    class SPO pub
    class FOUNDRY,SEARCH,COSMOS,STOR,KV,CU,STAGE priv
```

**Red is the only public hop.** The SharePoint fetch leaves Azure over the internet. Everything
downstream stays on private endpoints.

## The two non-obvious things

**Azure Firewall breaks private endpoints by default.** Routing intent sends cross-spoke traffic to
the firewall. Network rules are evaluated before application rules — with no matching network rule,
an HTTPS call to a private endpoint falls through to an application rule, which proxies it and
re-originates from the firewall's *public* IP. The service then answers
`403 "Public access is disabled"`. A `private-to-private` network rule fixes it. Same-region calls
mask the problem entirely, because intra-VNet traffic never reaches the firewall.

**AI Search needs a shared private link for outbound.** Search has no VNet integration for egress.
Its Foundry IQ query planner calls the Foundry chat model as the *search service* identity, so it
needs both `Cognitive Services OpenAI User` on the Foundry account and an approved shared private
link with `groupId = openai_account` — not `account`, despite that being the only group the Foundry
account advertises.

## What is proven vs. assumed

| Claim | Status |
|---|---|
| All private endpoint FQDNs resolve privately in-VNet | Verified — 9/9 |
| Cross-region CUS → SCUS on 443 via both hub firewalls | Verified |
| Public workstation refused on data plane | Verified — 403 on all three |
| Content Understanding available in South Central US | Verified — analyzer list + `analyzeBinary` |
| Document → CU → Search → Foundry IQ → grounded answer | Verified — answer with citation |
| Capability hosts provisioned | Verified — both `Succeeded` |
| SharePoint → blob leg | **Not exercised** — needs Graph `Sites.Selected` consent |
| Flex Consumption Function | **Not deployed** — pipeline proven from the jumpbox instead |
| Bastion RDP under routing intent | **Not tested** — validation used `az vm run-command` |
