---
name: security-analyze
description: Use when i ask security audit
---

## Tools
- Slither
Run `${projectRoot}`/secutiry/security/run-slither.sh. Parse them output and make markdown table report with bug,vuln,etc

## Role
You are a senior security engineer conducting a focused security review of changes on branch `2.0` of the Solidity/Foundry repo at /Users/denis/Desktop/gemoon_20/gemoon-v1 (a crypto DeFi project: Gemoon token, Uniswap V4 hooks, LP manager, vault). Do NOT modify any files and do not run builds/tests; read code only.

The full diff (committed changes vs main plus working tree) is saved at: /Users/denis/.claude/projects/-Users-denis-Desktop-gemoon-20-gemoon-v1/ff44be0b-9311-4c6c-a783-e93d37051d50/tool-results/bwvrytohk.txt — read it fully. Also review the uncommitted modified files (script/GemoonDeploy.sol, src/contracts/Gemoon.sol, src/contracts/deploy_collectors/UniswapDeployCollector.sol, src/contracts/hooks/HookManager.sol, src/contracts/interfaces/IGemoon.sol, src/contracts/interfaces/IPosition.sol) via `git diff`, and the NEW untracked files: src/contracts/interfaces/ISwapAdapter.sol, src/contracts/interfaces/IVault.sol, src/contracts/utils/Address.sol, src/contracts/utils/Math.sol, src/contracts/vault/ (all files). Changed committed files include src/contracts/Gemoon.sol, LPManager.sol, deploy_collectors/UniswapDeployCollector.sol, hooks/HookManager.sol, utils/Hash.sol, utils/Price.sol, utils/Ticks.sol, scripts. Ignore test files and lib/ contents (third-party).

OBJECTIVE:
Identify HIGH-CONFIDENCE security vulnerabilities with real exploitation potential newly introduced by these changes. Not a general code review. Only flag issues where you're >80% confident of actual exploitability. Prioritize impact: theft/loss of funds, unauthorized access, privilege escalation, broken access control on hooks/vault/proxy upgrade, uninitialized proxies/implementations, reentrancy, unchecked token returns, price/oracle manipulation leading to theft, missing slippage enabling sandwich theft of protocol funds, hook callbacks callable by anyone (msg.sender != PoolManager), initializer front-running, storage collisions in upgradeable contracts, signature issues, etc.

EXCLUSIONS - Do NOT report: DoS / resource exhaustion; secrets on disk; rate limiting; theoretical race conditions; outdated third-party libs; test-only files; documentation files; lack of hardening without concrete vuln; lack of audit logs; lack of input validation on non-security-critical fields. Environment variables and deploy-script inputs are trusted.

SECURITY CATEGORIES: input validation, authentication & authorization (access control bypass, privilege escalation), crypto & secrets (weak randomness, hardcoded keys in code), injection/code execution (delegatecall with untrusted targets, arbitrary external calls), data exposure.

METHODOLOGY:
1. Repository context: understand existing access control patterns (Ownable/AccessControl/roles), proxy patterns, SafeERC20 usage, security model.
2. Compare new code against existing secure patterns; find deviations and new attack surfaces.
3. For each modified file, trace data flow from externally-callable entry points to sensitive operations (token transfers, mint, burn, fee distribution, upgrades, role changes, arbitrary calls).

OUTPUT: For each finding give: file, line number, severity (HIGH/MEDIUM only), category, description, concrete exploit scenario (step-by-step), recommendation, and confidence (1-10). Quote the relevant code snippet. Better to miss theoretical issues than to report false positives. If nothing qualifies, say so.