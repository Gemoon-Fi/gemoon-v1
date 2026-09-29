# Gemoon: интеграция через ABI

Короткая инструкция для тех, кто вызывает контракты из фронтенда, бэкенда или скриптов.
Детали устройства протокола в `README.md` репозитория контрактов.

## Адреса

| Контракт | ABI | Адрес |
|---|---|---|
| GemoonController | `IGemoonController.json` | |
| Vault | `IVault.json` | |
| HookManager | см. ниже, две функции | |
| USDG (pair-токен) | стандартный ERC20 | |
| Токен мема | `IGemoonToken.json` | адрес из `TokenCreated` |

Все контракты, кроме токенов мемов, стоят за прокси: адреса постоянные, версия читается через
`getVersion()` (`IGemoonable.json`).

## Что нужно знать сразу

- Каждый мем торгуется в паре с USDG в пуле Uniswap V4. Эмиссия 100 000 000 000 токенов,
  18 знаков, вся сразу в пуле. Создатель токенов на руки не получает.
- Хук удерживает 1.25% в USDG с каждой сделки. Закладывайте это в расчёт минимального выхода.
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
    creatorRewards: 0n,               // не используется
    creatorAddress: "0x...",          // обязательно, получает долю создателя
    rewardRecipient: "0x0000000000000000000000000000000000000000", // ноль = creatorAddress
  },
  vaultAssets: [                      // 1..5 активов, сумма weightBps = 10000
    { token: "0x...", weightBps: 6000 },
    { token: "0x...", weightBps: 4000 },
  ],
};
```

Правила для `vaultAssets`: каждый актив должен быть в allowlist волта, проверяется через
`Vault.isAssetAllowed(asset)`, без повторов. Набор активов после создания не меняется.

Контроллер и вызывающий адрес добавляются в админы токена автоматически и не удаляются.

Что прочитать из транзакции:

| Событие | Поля | Зачем |
|---|---|---|
| `TokenCreated` | `tokenAddress`, `creatorAdmin`, `positionId`, `creatorRewardRecipient`, `name`, `symbol` | адрес токена |
| `PoolCreated` | `pool`, `token0`, `token1`, `initialPrice`, `tick` | id пула и стартовая цена |
| `PositionCreated` | `token`, `positionId`, `tickLower`, `tickUpper`, `liquidity` | позиция с ликвидностью |

## Торговать

Пул стандартный для Uniswap V4, подходит любой роутер, например Universal Router.
Ключ пула:

| Поле | Значение |
|---|---|
| `currency0`, `currency1` | адреса мема и USDG по возрастанию |
| `fee` | 0 |
| `tickSpacing` | 200 |
| `hooks` | адрес HookManager |

Комиссия 1.25% в USDG берётся хуком: при покупке за фиксированную сумму USDG из этой суммы,
при продаже из полученного USDG. LP-комиссии у пула нет.

HookManager для интеграций:

- `pendingFees(meme) → uint256`: комиссия по мему, ещё не выплаченная волту и протоколу.
- `distribute(meme)`: выплатить накопленное. Может вызвать любой. Нужна, если после сделок
  `pendingFees` не обнулился, такое бывает у пулов с малым оборотом.

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
   забирает награды за один вызов.

`emergencyUnstake(meme)` возвращает стейк даже на паузе, но всё заработанное с последнего
`stake`, `unstake` или `claim` теряется. Использовать только когда обычный вывод недоступен.

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

- Чтение: `imageAddress()`, `description()`, `getSocialMedia()`, `showAdmins()`.
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
| Vault | `Staked`, `Unstaked`, `EmergencyUnstaked`, `RewardPaid`, `CreatorRewardPaid` | действия пользователей |
| Vault | `CreatorTransferStarted`, `CreatorTransferred` | смена создателя |
| Token | `UpdateImage`, `UpdateDescription` | смена метаданных |

## Типичные ошибки

| Ошибка | Причина |
|---|---|
| `HookNotSet`, `VaultNotSet`, `PositionManagerNotSet` | контроллер ещё не сконфигурирован |
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
