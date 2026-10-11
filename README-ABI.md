# Gemoon: интеграция через ABI

Короткая инструкция для тех, кто вызывает контракты из фронтенда, бэкенда или скриптов.
Детали устройства протокола в `README.md` репозитория контрактов.

## Адреса

| Контракт | ABI | Адрес |
|---|---|---|
| GemoonController | `IGemoonController.json` | |
| Vault | `IVault.json` | |
| HookManager | `IHookManager.json` | |
| PoolManager (Uniswap V4) | `IPoolManager.json` | |
| USDG (pair-токен) | стандартный ERC20 | |
| Токен мема | `IGemoonToken.json` | адрес из `TokenCreated` |

Все контракты, кроме токенов мемов, стоят за прокси: адреса постоянные, версия читается через
`getVersion()` (`IGemoonable.json`).

## Что нужно знать сразу

- Каждый мем торгуется в паре с USDG в пуле Uniswap V4. Эмиссия 1 000 000 000 токенов,
  18 знаков, вся сразу в пуле. Стартовая капитализация 20 000 USDG: 50 000 мемов за 1 USDG. Создатель получает токены, только если сделал dev buy
  (см. ниже).
- Хук удерживает комиссию в USDG с каждой сделки. Ставку от 1% до 10% выбирает создатель мема,
  но **первые 30 секунд после создания пула она до 80%** (защита от снайперов). Закладывайте
  это в расчёт минимального выхода, ставку на момент сделки даёт `currentFeeBips(meme)`.
- Награды стейкерам и создателю выплачиваются не в USDG, а в наградных активах мема, и только
  после конвертации, которую периодически запускает keeper протокола.

## Создать токен

`GemoonController.deployToken(config)` возвращает адрес токена. Функция `payable`, но ETH не нужен.

```js
const config = {
  tokenConfig: {
    imgUrl: "ipfs://...",             // обязательно
    description: "...",
    socialMedia: { farcaster: "", twitterX: "", telegram: "", website: "" },
    name: "My Meme",                  // 1..150 символов
    symbol: "MEME",                   // 1..50 символов
    admins: [{ admin: "0x...", removable: true }], // минимум один
  },
  rewardsConfig: {
    swapFeeBips: 300n,                // комиссия свопа мема, 100..1000 (1%..10%)
    creatorAddress: "0x...",          // обязательно, получает долю создателя
    rewardRecipient: "0x0000000000000000000000000000000000000000", // ноль = creatorAddress
  },
  vaultAssets: [                      // 1..5 активов, сумма weightBps = 10000
    { token: "0x...", weightBps: 6000 },
    { token: "0x...", weightBps: 4000 },
  ],
  devBuy: {                           // первая покупка создателем, в той же транзакции
    memeAmount: 0n,                   // сколько мема купить, raw units (18 знаков). 0 = без dev buy
    maxPairIn: 0n,                    // максимум USDG с комиссией, иначе revert DevBuySlippage
  },
};
```

Правила для `vaultAssets`: каждый актив должен быть в allowlist волта, без повторов. Весь
allowlist отдаёт `Vault.allowedAssets()`, проверка одного актива — `Vault.isAssetAllowed(asset)`.
Какие из них показывать в форме, см. `indexing.md`, раздел 2a. Набор активов после создания не меняется.

Контроллер и вызывающий адрес добавляются в админы токена автоматически и не удаляются.

### Dev buy

Создатель может купить часть эмиссии сразу при создании, в той же транзакции. Между созданием
пула и этой покупкой никто встать не может, снайперы торгуют уже после неё и по сдвинутой цене.

- Покупку делает сам контроллер напрямую через PoolManager, а не 0x или другой роутер: до
  транзакции пула ещё нет, котировку взять неоткуда.
- Платит и получает мем **вызывающий** `deployToken` адрес (`msg.sender`).
- Перед вызовом нужен `USDG.approve(GemoonController, maxPairIn)`. Контроллер списывает ровно
  стоимость покупки, остаток approve остаётся.
- Комиссия: базовая ставка мема (`rewardsConfig.swapFeeBips`), без надбавки 80% анти-снайп окна.
- Лимит: не больше 80% эмиссии (`MAX_DEV_BUY_X18` = 800 000 000 токенов), иначе
  `DevBuyTooLarge(memeAmount, max)`.
- Ориентир стоимости по цене пула без комиссии: доля `f` эмиссии стоит примерно
  `20 000 × f / (1 − f)` USDG плюс несколько процентов (позиция начинается на 1–2 шага тиков выше
  стартовой цены). 10% ≈ 2 200 USDG, 50% ≈ 20 000, 80% ≈ 80 000–85 000. Точную сумму даёт
  симуляция.
- Покупка exact output: приходит ровно `memeAmount`. Стоимость детерминирована, её можно узнать
  симуляцией `deployToken` через `eth_call` с большим `maxPairIn`, она будет в событии `DevBuy`.
  Затем отправить транзакцию с этой суммой в `maxPairIn`. Если стоимость выше, revert
  `DevBuySlippage(pairIn, maxPairIn)`.
- Комиссия dev buy, как у любой первой покупки, может остаться в `pendingFees` до следующего
  свопа.

Что прочитать из транзакции:

| Событие | Поля | Зачем |
|---|---|---|
| `TokenCreated` | `tokenAddress`, `creatorAdmin`, `positionId`, `creatorRewardRecipient`, `name`, `symbol` | адрес токена |
| `PoolCreated` | `pool`, `token0`, `token1`, `initialPrice`, `tick` | id пула и стартовая цена |
| `PositionCreated` | `token`, `positionId`, `tickLower`, `tickUpper`, `liquidity` | позиция с ликвидностью |
| `DevBuy` | `token`, `buyer`, `pairIn`, `memeOut` | только при dev buy: сколько заплачено USDG с комиссией и получено мема |

При dev buy хук также эмитит обычный `MemeSwapped`, где `router` — адрес контроллера, `trader` —
покупатель.

## Торговать

Пул стандартный для Uniswap V4, подходит любой роутер, например Universal Router.

**Газ.** Сделка, после которой накопленная комиссия волта мема переходит порог, в той же
транзакции конвертирует её в наградные активы. Поэтому **каждая** сделка мема должна нести лимит
газа с запасом под конвертацию, даже если сама порог не пересечёт: к моменту включения в блок
порог могут набрать чужие сделки. Запас порядка 150k + 300k на каждый наградной актив кроме USDG
сверх обычного свопа; списывается только израсходованный газ. Если лимита не хватает, сделка
откатывается с ошибкой `NotEnoughGasForConversion(needed, available)` хука (внутри
`WrappedError` PoolManager). Кошельки и агрегаторы, которые считают газ симуляцией
(`eth_estimateGas`, 0x), заложат его сами; при ручном лимите брать с запасом. Размер запаса:
`Vault.conversionGasRequired(meme)` (0, если автоконвертация выключена).
Ключ пула:

| Поле | Значение |
|---|---|
| `currency0`, `currency1` | адреса мема и USDG по возрастанию |
| `fee` | 0 |
| `tickSpacing` | 200 |
| `hooks` | адрес HookManager |

Комиссия в USDG берётся хуком: при покупке за фиксированную сумму USDG из этой суммы,
при продаже из полученного USDG. LP-комиссии у пула нет.

Базовую ставку мема задаёт создатель в `rewardsConfig.swapFeeBips`, от 100 до 1000 bips (1%..10%).
Из неё протокол получает треть (`PROTOCOL_SHARE_BIPS` = 3333, то есть 33.33%), волт мема
остальное: при 3% это ~1% от сделки протоколу и ~2% волту, при 1% — ~0.33% и ~0.67%, при 10% —
~3.33% и ~6.67%.

Ставка зависит от возраста пула: в момент создания 80%, дальше линейно падает и через
`DYNAMIC_FEE_THRESHOLD()` секунд (сейчас 30) становится базовой. Dev buy внутри `deployToken`
платит сразу базовую ставку. Доля протокола (треть) действует и в этом окне, от всей
комиссии вместе с надбавкой. Время создания пула берётся из блока `deployToken`.

HookManager для интеграций (`IHookManager.json`):

- `pendingFees(meme) → uint256`: комиссия по мему, ещё не выплаченная волту и протоколу.
- `distribute(meme)`: выплатить накопленное. Может вызвать любой. Нужна, если после сделок
  `pendingFees` не обнулился, такое бывает у пулов с малым оборотом.
- `currentFeeBips(meme) → uint256`: ставка комиссии в bips прямо сейчас, с учётом окна
  после создания пула. `feeBipsAt(meme, timestamp)` — то же на заданный момент.
- `memeFeeBips(meme)`, `baseFeeBips(meme)`: ставка, выбранная создателем, и ставка после окна.
- `PROTOCOL_SHARE_BIPS()`, `BIPS()`: доля протокола в bips от комиссии (3333 = треть).
  До этой версии назывался `PROTOCOL_FEE_BIPS()` и означал bips от суммы сделки. `MIN_MEME_FEE_BIPS()`,
  `MAX_MEME_FEE_BIPS()` — границы ставки создателя. `MAX_FEE_BIPS()` (8000) и
  `DYNAMIC_FEE_THRESHOLD()` задают окно повышенной комиссии, `poolTimestamps(meme)` — время
  создания пула.
- Событие `MemeFeeConfigured(meme, feeBips, createdAt)`: выбранная ставка и начало окна.
- События `MemeSwapped`, `FeeCharged`, `FeesDistributed`, `PayoutFailed`: сигнатуры в
  `indexing.md`.

## Стейкинг

Стейкается сам токен мема, награды приходят в его наградных активах.

1. `approve(vault, amount)` на токене мема, затем `Vault.stake(meme, amount)`.
   Или без approve: `Vault.stakeWithPermit(meme, amount, deadline, v, r, s)`, токен
   поддерживает EIP-2612.
2. Читать состояние:
   - `stakedOf(meme, account)`, `totalStaked(meme)`;
   - `pendingCreditOf(meme, account)`: заработанный USDG, который ещё не сконвертирован и пока
     не забирается;
   - `earned(meme, account) → (assets[], amounts[])`: что можно забрать прямо сейчас;
   - `getAssets(meme)`: наградные активы и их веса.
3. Забрать: `claim(meme)` всё, либо `claim(meme, assets[])` только выбранные активы.
4. Выйти: `unstake(meme, amount)`, награды остаются claimable. `exit(meme)` снимает весь стейк и
   забирает награды за один вызов. `unstake` работает и на паузе, `exit` и `claim` — нет.

Стейкер получает долю только от комиссий, пришедших пока он застейкан. Если стейкеров нет, вся
комиссия уходит создателю.

## Создатель

- `creatorOf(meme)`: текущий создатель.
- `creatorAccrued(meme) → (assets[], amounts[])`: доля создателя, готовая к выплате.
- `claimCreatorRewards(meme)`: отправляет её создателю. Вызвать может любой адрес.
- Передача роли в два шага: создатель зовёт `transferCreator(meme, newCreator)`, новый адрес
  зовёт `acceptCreator(meme)`. Невыплаченные награды переходят вместе с ролью.
  Ноль в `newCreator` отменяет передачу.

## Токен мема

`IGemoonToken`: ERC20 плюс permit и burn.

- Чтение: `creator()`, `imageAddress()`, `description()`, `getSocialMedia()`, `showAdmins()`.
- Только админ: `updateImage(url)`, `changeDescription(text)`.
- Замена админа: `GemoonController.changeAdmin(token, oldAdmin, newAdmin)`. Заменить можно
  только админа с `removable = true`.

## События для индексации

| Контракт | Событие | Смысл |
|---|---|---|
| Controller | `TokenCreated`, `PoolCreated`, `PositionCreated` | новый мем |
| Vault | `VaultRegistered(meme, creator, assets)` | волт мема создан |
| Vault | `FeesNotified(meme, toStakers, toCreator)` | пришла комиссия в USDG |
| Vault | `FeesConverted(meme, epoch, usdgIn, toStakers[], toCreator[])` | USDG сконвертирован, награды стали claimable |
| Vault | `Staked`, `Unstaked`, `RewardPaid`, `CreatorRewardPaid` | действия пользователей |
| Vault | `CreatorTransferStarted`, `CreatorTransferred` | смена создателя |
| Token | `UpdateImage`, `UpdateDescription` | смена метаданных |

## Типичные ошибки

| Ошибка | Причина |
|---|---|
| `HookNotSet`, `VaultNotSet`, `PositionManagerNotSet` | контроллер ещё не сконфигурирован |
| `InvalidMemeFeeBips(feeBips)` | `swapFeeBips` вне 100..1000 |
| `Token symbol is required`, `Token name is required`, `Token image required.`, `At least one admin address is required.` | пустые поля конфига |
| `AssetNotAllowed`, `DuplicateAsset`, `InvalidAssetsLength`, `InvalidWeights` | неверный `vaultAssets` |
| `VaultNotRegistered` | адрес не является мемом Gemoon |
| `InsufficientStake` | снятие больше стейка |
| `EnforcedPause` | волт на паузе: стейк, клейм и конвертация недоступны, вывод стейка работает |
| `NotCreator`, `NotPendingCreator` | смена создателя не тем адресом |
| `Caller is not an admin` | метаданные токена меняет не админ |

## Для keeper и адаптеров

`Vault.convertFees(meme, minAmountsOut[])` меняет весь накопленный USDG мема на наградные активы
и закрывает эпоху. Только keeper. `minAmountsOut` в порядке `getAssets(meme)`. До вызова
`pendingUSDG(meme)` показывает сумму к конвертации.

Адаптер обмена реализует `ISwapAdapter.swap(tokenIn, tokenOut, amountIn, minAmountOut, recipient)`:
входной токен уже переведён на адаптер, выход нужно отправить на `recipient`, при выходе ниже
`minAmountOut` откатиться. Волт измеряет результат по своему балансу, а не по возвращаемому значению.
