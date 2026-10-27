# Комиссии: какая процентовка куда уходит и где считается

Карта всех процентов протокола: размер, кто получает, в каком контракте и в какой функции
считается, как округляется. Ссылки вида `Vault.sol:274` — файл и строка на момент написания
документа; если строки сдвинулись, ищите по имени функции.

Единицы измерения в коде:

| Единица | Знаменатель | Где |
|---|---|---|
| bips / bps | `10_000` | `HookManager.BIPS`, `Vault.BPS`, `GmoonReferrals.BIPS`, `UniswapV3SwapAdapter.BPS` |
| ppm (parts per million) | `1_000_000` | `FeeInfo` в `Token.sol` — только снимок для метаданных |
| percent (1e18) | `PRECISION = 1e18` | `utils/Percent.sol` — вспомогательная библиотека, в расчёте комиссий **не участвует** |

Bips и bps в проекте — одно и то же (`/10_000`), разные написания остались исторически.

---

## 1. Общая схема

Комиссия всегда берётся **в pair-токене (USDG)**, с каждого свопа в пуле Meme/USDG. Один раз её
размер считает хук, дальше её делят три контракта подряд:

```
                     своп в пуле Meme/USDG
                              │
                              │  ставка = swapFeeBips мема (1%..5%),
                              │  первые 15 с — анти-снайп до 80%
                              ▼
           ┌──────────────────────────────────┐
           │ HookManager  — считает РАЗМЕР     │   HookManager.sol:392 `_feeOf`
           │ разбивки не знает, всё → волт     │   HookManager.sol:452 `_payout`
           └──────────────────┬───────────────┘
                              │ 100% комиссии
                              ▼
           ┌──────────────────────────────────┐
           │ Vault.notifyFees                 │   Vault.sol:274
           │  protocolShareBps = 25%          │
           └───────┬──────────────────┬───────┘
                   │ 25%              │ 75%
                   ▼                  ▼
      ┌───────────────────┐   ┌──────────────────────────────┐
      │ GmoonReferrals    │   │ Vault._creditFees            │   Vault.sol:304
      │ notifyFee         │   │  creatorShareBps = 0..50%    │
      └───┬───────────┬───┘   └──────┬────────────────┬──────┘
          │ 25%       │ 75%          │ creatorShare   │ остаток
          ▼           ▼              ▼                ▼
      реферер     протокол       создатель         стейкеры
                                   (в USDG, конвертируется по весам активов)
```

Каждый шаг делит **результат предыдущего**, а не сумму сделки. Поэтому проценты перемножаются:
доля реферера от сделки = `swapFee × protocolShare × refShare`.

---

## 2. Шаг 1 — размер комиссии (HookManager)

**Где считается:** `src/contracts/hooks/HookManager.sol`

```solidity
// HookManager.sol:392
function _feeOf(address meme, address sender, uint256 amount) internal view returns (uint256) {
    uint256 bips = sender == controller
        ? baseFeeBips(meme)                   // dev buy — всегда базовая ставка
        : feeBipsAt(meme, block.timestamp);   // все остальные — с учётом анти-снайпа
    return (amount * bips) / BIPS;
}
```

Вызывается из `_beforeSwap` (HookManager.sol:249), если объём USDG задал пользователь, иначе из
`_afterSwap` (HookManager.sol:271). Сумма, от которой берётся процент, — всегда объём **в USDG**.

| Ставка | Значение | Где хранится | Кто задаёт |
|---|---|---|---|
| Базовая ставка мема | 1%..5% (100..500 bips) | `memeFeeBips[meme]`, HookManager.sol:111 | Создатель в `deployToken` → `rewardsConfig.swapFeeBips` → `notifyPoolCreated` (HookManager.sol:476) |
| Границы базовой ставки | `MIN_MEME_FEE_BIPS = 100`, `MAX_MEME_FEE_BIPS = 500` | HookManager.sol:77-78 | Константы, не меняются |
| Резервная ставка | 1.25% (125 bips) | `TOTAL_FEE_BIPS`, immutable, HookManager.sol:70 | Конструктор, `HOOK_TOTAL_FEE_BIPS` в env |
| Анти-снайп, старт | 80% (`MAX_FEE_BIPS = 8_000`) | HookManager.sol:75 | Константа |
| Анти-снайп, окно | 15 секунд (`DYNAMIC_FEE_THRESHOLD`) | HookManager.sol:72 | Константа |

`baseFeeBips(meme)` (HookManager.sol:493) отдаёт `memeFeeBips[meme]`, а если контроллер о меме не
сообщал — `TOTAL_FEE_BIPS`.

**Анти-снайп** — линейное падение от 80% до базовой ставки за 15 секунд
(`feeBipsAt`, HookManager.sol:506):

```solidity
uint256 decay = ((MAX_FEE_BIPS - baseFee) * elapsed) / DYNAMIC_FEE_THRESHOLD;
return MAX_FEE_BIPS - decay;
```

`decay` округляется вниз → ставка округляется вверх, в пользу протокола. Отсчёт идёт от
`poolTimestamps[meme]`, который хук пишет сам в `_afterInitialize` (HookManager.sol:234) и только
для первого пула мема, созданного контроллером. Исключение — свопы самого контроллера, то есть
dev buy внутри `deployToken`: они платят базовую ставку (проверка `sender == controller` в
`_feeOf`).

**Разбивки хук не делает.** Накопленное лежит в `accrued[meme]` (HookManager.sol:103) и целиком
уходит в волт в `_payout` (HookManager.sol:452): `poolManager.take(i_pairToken, vault, amount)` +
`IVault.notifyFees(meme, amount)`. Хук неизменяемый, поэтому ни ставку, ни получателя комиссии
живого пула изменить нельзя.

---

## 3. Шаг 2 — доля протокола (Vault)

**Где считается:** `src/contracts/vault/Vault.sol:274`, функция `notifyFees`

```solidity
// Vault.sol:274
uint256 toProtocol = (usdgAmount * s_protocolShareBps) / BPS;
uint256 toVault    = usdgAmount - toProtocol;
```

| Параметр | Значение | Где |
|---|---|---|
| `protocolShareBps` | 2500 bps = **25% всей комиссии** | `s_protocolShareBps`, Vault.sol:159 |
| Потолок | 100% (`BPS`) | `setProtocolShare`, Vault.sol:541 |
| Получатель | `protocolRecipient` — в проде это `GmoonReferrals` | `s_protocolRecipient`, Vault.sol:156 |
| Значение при деплое | `VAULT_PROTOCOL_SHARE_BPS=2500` | `env/prod.mk:30`, `env/dev.mk:31` |

- Округление `toProtocol` **вниз**, пыль остаётся волту мема.
- Доля берётся от **всей** комиссии, включая анти-снайп надбавку.
- Параметр **глобальный**: меняется владельцем волта (`setProtocolShare`) и действует для всех
  мемов с ближайшей выплаты. Исторические мемы не исключение.
- Перевод: `usdg_.safeTransfer(recipient, toProtocol)` (Vault.sol:287). Если у получателя есть код,
  волт зовёт `IProtocolFeeReceiver.notifyFee(meme, toProtocol)` (Vault.sol:289); EOA не уведомляется.
- Если доля > 0, а получатель не задан — `notifyFees` падает с `ProtocolRecipientNotSet`, комиссия
  остаётся накопленной в хуке.

---

## 4. Шаг 3 — доля создателя и стейкеров (Vault)

**Где считается:** `src/contracts/vault/Vault.sol:304`, функция `_creditFees`

```solidity
// Vault.sol:304 — amount здесь это toVault, то есть 75% комиссии
uint256 toCreator = (amount * v.creatorShareBps) / BPS;
uint256 toStakers = amount - toCreator;
```

| Параметр | Значение | Где |
|---|---|---|
| `creatorShareBps` | 0..5000 bps = **0..50% волтовой части** | `VaultInfo.creatorShareBps`, `IVault.sol:36` |
| Потолок | `MAX_CREATOR_SHARE_BPS = 5_000` | Vault.sol:101 |
| Кто задаёт | Создатель в `deployToken` → `config.vaultCreatorShareBps` → `registerVault` (Vault.sol:219) | |
| Изменяемость | **Фиксируется навсегда** при регистрации волта | |

Проверка потолка — `registerVault`, Vault.sol:227 (`InvalidCreatorShare`).

**Важное исключение (Vault.sol:307-316):** если стейкеров нет (`totalStaked == 0`) или сумма
слишком мала, чтобы сдвинуть аккумулятор (`accDelta == 0`), **вся** волтовая часть идёт создателю,
независимо от `creatorShareBps`. То есть стейкер зарабатывает только на комиссиях, пришедших пока
он застейкан.

Начисления копятся в USDG: `pendingCreatorUSDG` и `pendingStakerUSDG` (Vault.sol:318-319), доля
стейкера считается через аккумулятор `accUsdPerShare += toStakers * PRECISION / totalStaked`
(`PRECISION = 1e36`, Vault.sol:103).

---

## 5. Шаг 4 — реферальная доля (GmoonReferrals)

**Где считается:** `src/contracts/Referrals.sol:209`, функция `notifyFee`

```solidity
// Referrals.sol:211
uint256 refAmount = referrer == address(0)
    ? 0
    : (amount * s_refShareBips) / BIPS;
```

| Параметр | Значение | Где |
|---|---|---|
| `refShareBips` | 2500 bips = **25% протокольной доли** | `s_refShareBips`, Referrals.sol:63 |
| Потолок | 100% (`BIPS`) | `_setRefShare`, Referrals.sol:389 |
| Значение при деплое | `REFERRALS_REF_SHARE_BIPS=2500` | `env/prod.mk:40`, `env/dev.mk:54` |

- `amount` здесь — **только протокольная доля**, которую волт уже перевёл, а не вся комиссия.
- Округление вниз, в пользу протокола.
- Реферер берётся из `s_memeReferrer[meme]` — он закрепляется за мемом один раз в `registerToken`
  (Referrals.sol:193), вызываемом из `deployToken` по реферреру **деплоера**. Привязка, сделанная
  позже, на уже созданные мемы не действует.
- Мемы без реферера: `refAmount = 0`, всё остаётся протоколу. Функция никогда не ревертится из-за
  отсутствия реферера, иначе блокировала бы выплату комиссии.
- Что считается протокольной частью: `protocolBalance() = balanceOf(this) - totalPending`
  (Referrals.sol:367) — всё, что не должно реферерам. Забирается `withdrawProtocolFees(to)`.
- `refShareBips` глобальный, применяется к комиссиям, пришедшим после изменения.

---

## 6. Шаг 5 — веса наградных активов (Vault.convertFees)

Это не доля комиссии, а разбивка уже начисленного USDG по активам, в которых стейкеры и создатель
получают награду.

**Где считается:** `src/contracts/vault/Vault.sol:359`

```solidity
uint256 amountIn = i == n - 1
    ? total - spent                              // последнему активу — остаток, чтобы не было пыли
    : (total * assets[i].weightBps) / BPS;
```

| Параметр | Значение | Где |
|---|---|---|
| `weightBps` активов | Сумма строго `10_000` (100%), каждый > 0 | `registerVault`, Vault.sol:244-247 (`InvalidWeights`) |
| Количество активов | 1..8 (`MAX_ASSETS`) | Vault.sol:102 |
| Кто задаёт | Создатель в `deployToken` → `config.vaultAssets`, только из allowlist волта | |

После свопов выход каждого актива делится между создателем и стейкерами **пропорционально их долям
в USDG эпохи**, а не ещё раз по bps (Vault.sol:372):

```solidity
toCreator[i] = Math.mulDiv(out, creatorUsd, total);
toStakers[i] = out - toCreator[i];
```

---

## 7. Защита цены при конвертации (UniswapV3SwapAdapter)

Тоже процент, но не распределение, а допуск отклонения от TWAP.

**Где считается:** `src/contracts/adapters/UniswapV3SwapAdapter.sol:104-105`

```solidity
expected = quoteAtTwapTick(amountIn * (1e6 - poolFee) / 1e6);   // комиссия пула V3 в ppm
minOut   = expected * (BPS - route.maxSlippageBps) / BPS;
```

| Параметр | Значение | Где |
|---|---|---|
| `maxSlippageBps` на актив | Задаёт владелец адаптера, рекомендуемо 100 bps (1%) | `setRoute` |
| Потолок | `MAX_SLIPPAGE_BPS = 1000` (10%) | UniswapV3SwapAdapter.sol:43 |
| Комиссия пула V3 | fee-tier пула, в ppm (`FEE_DENOMINATOR = 1e6`) | UniswapV3SwapAdapter.sol:41 |
| Окно TWAP | 1 минута … 1 час, по умолчанию 600 с | `MIN_TWAP_WINDOW`, `MAX_TWAP_WINDOW` |

---

## 8. Снимок разбивки в метаданных токена (FeeInfo)

Отдельная, **справочная** копия разбивки, вшитая в токен при деплое, чтобы фронт и маркетплейсы
читали её из одного места.

**Где считается:** `src/contracts/Gemoon.sol:296`, функция `_feeInfo` (чистая, вызывается один раз
в `deployToken`)

```solidity
uint256 total       = min(swapFeeBips, uint16.max) * 100;              // bips -> ppm
uint256 protocol    = (total * protocolShareBips) / 10_000;
uint256 vaultPart   = total - protocol;
uint256 creatorPart = (vaultPart * min(creatorShareBps, 10_000)) / 10_000;
// FeeInfo{ totalPpm: total, creatorPpm: creatorPart, vaultPpm: vaultPart - creatorPart, protocolPpm: protocol }
```

- Инвариант `creatorPpm + vaultPpm + protocolPpm == totalPpm` проверяется в конструкторе токена
  (`Token.sol:47`, `InvalidFeeInfo`). Каждая часть округляется вниз, пыль достаётся стейкерам
  (`vaultPpm`), поэтому сумма всегда сходится.
- `vaultPpm` в этой структуре — это **доля стейкеров**, а не вся волтовая часть.
- Реферальной доли в `FeeInfo` нет.
- Читается через `IToken.feeInfo()` (`Token.sol:91`) и в JSON `tokenURI` — объект `fees` с полями
  `totalPercent`, `creatorPercent`, `vaultPercent`, `protocolPercent` в процентах
  (`Token.sol:224`, формат числа — `_percent`, `Token.sol:242`).
- **Это снимок на момент деплоя.** Владелец волта может потом изменить `protocolShareBps`, и тогда
  реальная разбивка разойдётся со вшитой в токен. Источник истины — волт.

---

## 9. Итоговая таблица: процент от суммы сделки

При параметрах по умолчанию (`protocolShareBps = 2500`, `refShareBips = 2500`), после окончания
анти-снайп окна.

| Получатель | Формула от сделки | Ставка 1% | Ставка 5% |
|---|---|---|---|
| Комиссия всего | `swapFeeBips` | 1% | 5% |
| ├─ Протокол (всего) | `× 25%` | 0.25% | 1.25% |
| │   ├─ реферер мема | `× 25% × 25%` | 0.0625% | 0.3125% |
| │   └─ протокол нетто | `× 25% × 75%` | 0.1875% | 0.9375% |
| └─ Волт мема | `× 75%` | 0.75% | 3.75% |
| &nbsp;&nbsp;&nbsp;&nbsp;├─ создатель | `× 75% × creatorShareBps` | 0..0.375% | 0..1.875% |
| &nbsp;&nbsp;&nbsp;&nbsp;└─ стейкеры | `× 75% × (1 - creatorShareBps)` | 0.375..0.75% | 1.875..3.75% |

Если у мема нет реферера, его 0.0625% / 0.3125% остаются протоколу.
Если стейкеров нет, вся волтовая часть идёт создателю.

**Числовой пример.** Своп на 1 000 USDG, ставка 5%, `creatorShareBps = 5000`, реферер есть:

| Шаг | Контракт | Сумма |
|---|---|---|
| Комиссия | `HookManager._feeOf` | `1000 × 500 / 10000` = **50 USDG** |
| Протоколу | `Vault.notifyFees` | `50 × 2500 / 10000` = **12.5 USDG** |
| Волту мема | `Vault.notifyFees` | `50 − 12.5` = **37.5 USDG** |
| Рефереру | `GmoonReferrals.notifyFee` | `12.5 × 2500 / 10000` = **3.125 USDG** |
| Протоколу нетто | `GmoonReferrals.protocolBalance` | `12.5 − 3.125` = **9.375 USDG** |
| Создателю | `Vault._creditFees` | `37.5 × 5000 / 10000` = **18.75 USDG** |
| Стейкерам | `Vault._creditFees` | `37.5 − 18.75` = **18.75 USDG** |

**Пример для анти-снайпа.** Та же сделка на 10-й секунде жизни пула, базовая ставка 5%:
`feeBipsAt = 8000 − ((8000 − 500) × 10 / 30) = 8000 − 2500 = 5500` → комиссия 55% = 550 USDG.
Делится ровно по тем же правилам: 137.5 протоколу, 412.5 волту мема.

---

## 10. Где прочитать актуальные значения ончейн

| Что | Вызов |
|---|---|
| Ставка мема сейчас (с анти-снайпом) | `HookManager.currentFeeBips(meme)` |
| Ставка мема в момент t | `HookManager.feeBipsAt(meme, timestamp)` |
| Базовая ставка мема | `HookManager.baseFeeBips(meme)` |
| Резервная ставка | `HookManager.TOTAL_FEE_BIPS()` |
| Доля протокола | `Vault.protocolShareBps()` |
| Получатель протокольной доли | `Vault.protocolRecipient()` |
| Доля создателя мема | `Vault.creatorShareBpsOf(meme)` |
| Реферальная доля | `GmoonReferrals.refShareBips()` |
| Реферер мема | `GmoonReferrals.memeReferrer(meme)` |
| Снимок разбивки в токене | `IToken.feeInfo()` или `tokenURI()` → `fees` |
| Начислено, но не выплачено хуком | `HookManager.pendingFees(meme)` |
| Начислено в USDG в открытой эпохе | `Vault.pendingUSDG(meme)` |

---

## 11. Кто и что может изменить

| Процент | Изменяемость | Кто |
|---|---|---|
| Базовая ставка мема | **Нет**, фиксируется в блоке создания пула (`PoolAlreadyNotified`, `PoolNotCreatedInThisBlock`) | — |
| `TOTAL_FEE_BIPS`, `MAX_FEE_BIPS`, границы ставки мема, окно анти-снайпа | **Нет**, хук не обновляемый | — |
| `protocolShareBps` | Да, глобально, без таймлока | Владелец волта, `setProtocolShare` |
| `protocolRecipient` | Да | Владелец волта, `setProtocolRecipient` |
| `creatorShareBps` мема | **Нет**, фиксируется в `registerVault` | — |
| `refShareBips` | Да, глобально | Владелец рефералов, `setRefShare` |
| Веса наградных активов мема | **Нет**, фиксируются в `registerVault` | — |
| `maxSlippageBps` маршрута | Да | Владелец адаптера, `setRoute` |

Владелец волта по итогам `TransferToGovernance` — Safe без таймлока, поэтому смена доли протокола
вступает в силу немедленно.
