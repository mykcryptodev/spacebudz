{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}


import Playground.Contract
import Wallet.Emulator.Wallet as Emulator
import Plutus.Contract
import           Data.Map             as Map
import qualified Prelude              as Haskell
--
import           Control.Monad        hiding (fmap)
import           Data.Aeson           (ToJSON, FromJSON,encode)
import           Data.List.NonEmpty   (NonEmpty (..))
import           Data.Text            (pack, Text)
import           GHC.Generics         (Generic)
import qualified PlutusTx
import           PlutusTx.Prelude     as P
import           Ledger               hiding (singleton)
import           Ledger.Credential    (Credential (..))
import           Ledger.Constraints   as Constraints
import qualified Ledger.Scripts       as Scripts
import qualified Ledger.Typed.Scripts as Scripts
import           Ledger.Value         as Value
import           Ledger.Ada           as Ada hiding (divide)
import           Prelude              ((/), Float, toInteger, floor)
import           Text.Printf          (printf)
import qualified PlutusTx.AssocMap    as AssocMap
import qualified Data.ByteString.Short as SBS
import qualified Data.ByteString.Lazy  as LBS
import           Cardano.Api hiding (Value, TxOut)
import           Cardano.Api.Shelley hiding (Value, TxOut)
import           Codec.Serialise hiding (encode)
import qualified Plutus.V1.Ledger.Api as Plutus

-- Contract

-- Total Fee: 2.5%

-- Owner1 Fee: 1.95%
-- Owner2 Fee: 0.5%
-- Hosting Provider Fee: 0.05%

data ContractInfo = ContractInfo
    { policySpaceBudz :: !CurrencySymbol
    , policyBid :: !CurrencySymbol
    , prefixSpaceBud :: !BuiltinByteString
    , prefixSpaceBudBid :: !BuiltinByteString
    , owner1 :: !(PubKeyHash, Integer, Integer, Integer)
    , owner2 :: !(PubKeyHash, Integer)
    , extraRecipient :: !Integer
    , minPrice :: !Integer
    , bidStep :: !Integer
    } deriving (Generic, ToJSON, FromJSON)

toFraction :: Float -> Integer
toFraction p = toInteger $ floor (1 / (p / 1000))


contractInfo = ContractInfo 
    { policySpaceBudz = "11e6cd0f89920242317a6cba919d7637008d119ff46a8c29de6f014a"
    , policyBid = "11e6cd0f89920242317a6cba919d7637008d119ff46a8c29de6f014a"
    , prefixSpaceBud = "SpaceBud"
    , prefixSpaceBudBid = "SpaceBudBid"
    , owner1 = ("2bd88ae9736d59bbd5714f0ded14648f8cffc9f5e8e85cea3bfb033f", 555, 500, 400) -- 1.8% 2% 2.5%
    , owner2 = ("9fb0a5cbecf77d8a8688749337f2f12538b7d3f90b8891c242d22867", 2000) -- 0.5%
    , extraRecipient = 5000 -- 0.2%
    , minPrice = 50000000
    , bidStep = 10000
    }

-- Data and Redeemers

data TradeDetails = TradeDetails
    { tradeOwner :: !PubKeyHash
    , budId :: !BuiltinByteString
    , requestedAmount :: !Integer
    } deriving (Generic, ToJSON, FromJSON)

instance Eq TradeDetails where
    {-# INLINABLE (==) #-}
    -- tradeOwner is not compared, since tradeOwner changes with each trade/higher bid
    a == b = (budId  a == budId  b) &&
             (requestedAmount a == requestedAmount b)

data TradeDatum = StartBid | Bid TradeDetails | Offer TradeDetails 
    deriving (Generic, ToJSON, FromJSON)

instance Eq TradeDatum where
    {-# INLINABLE (==) #-}
    StartBid == StartBid = True
    Bid a == Bid b = a == b
    Offer a == Offer b = a == b

data TradeAction = Buy | Sell | BidHigher | Cancel
    deriving (Generic, ToJSON, FromJSON)


-- Validator

{-# INLINABLE tradeValidate #-}
tradeValidate :: ContractInfo -> TradeDatum -> TradeAction -> ScriptContext -> Bool
tradeValidate contractInfo tradeDatum tradeAction context = case tradeDatum of
    StartBid -> case tradeAction of
        BidHigher -> correctStartBidOutputs

    Bid details -> case tradeAction of
        BidHigher -> 
            Bid details == scriptOutputDatum && -- expected correct script output datum
            Ada.fromValue (scriptInputValue) + Ada.lovelaceOf (bidStep contractInfo) <= Ada.fromValue scriptOutputValue && -- expected correct bid amount
            containsPolicyBidNFT scriptOutputValue (budId details) && -- expected correct bidPolicy NFT
            Ada.fromValue (valuePaidTo txInfo (tradeOwner details)) >= Ada.fromValue scriptInputValue -- expected previous bidder refund
        Sell -> 
            scriptOutputDatum == StartBid && -- expected correct script output datum
            containsPolicyBidNFT scriptOutputValue (budId details) && -- expected correct bidPolicy NFT
            containsSpaceBudNFT (valuePaidTo txInfo (tradeOwner details)) (budId details) && -- expected bidder to be paid
            correctSplit (getLovelace (Ada.fromValue scriptInputValue)) signer -- expected ada to be split correctly
        Cancel -> 
            txInfo `txSignedBy` tradeOwner details && -- expected correct owner
            scriptOutputDatum == StartBid && -- expected correct script output datum
            containsPolicyBidNFT scriptOutputValue (budId details) && -- expected correct bidPolicy NFT
            Ada.fromValue (valuePaidTo txInfo (tradeOwner details)) >= Ada.fromValue scriptInputValue -- expect correct refund

    Offer details -> case tradeAction of
        Buy ->
            containsSpaceBudNFT (valuePaidTo txInfo signer) (budId details) && -- expected buyer to be paid
            requestedAmount details >= minPrice contractInfo && -- expected at least minPrice buy
            correctSplit (requestedAmount details) (tradeOwner details) -- expected ada to be split correctly
        Cancel -> 
            txInfo `txSignedBy` tradeOwner details && -- expected correct owner
            containsSpaceBudNFT (valuePaidTo txInfo (tradeOwner details)) (budId details) -- expect correct refund

    where
        txInfo :: TxInfo
        txInfo = scriptContextTxInfo context

        policyAssets :: Value -> CurrencySymbol -> [(CurrencySymbol, TokenName, Integer)]
        policyAssets v cs = P.filter (\(cs',_,am) -> cs == cs' && am == 1) (flattenValue v)

        signer :: PubKeyHash
        signer = case txInfoSignatories txInfo of
            [pubKeyHash] -> pubKeyHash

        (owner1PubKeyHash, owner1Fee1, owner1Fee2, owner1Fee3) = owner1 contractInfo
        (owner2PubKeyHash, owner2Fee1) = owner2 contractInfo

        -- minADA requirement forces the contract to give up certain fee recipients
        correctSplit :: Integer -> PubKeyHash -> Bool
        correctSplit lovelaceAmount tradeRecipient
            | lovelaceAmount > 800000000 = let (amount1, amount2, amount3) = (lovelacePercentage lovelaceAmount (owner1Fee1),lovelacePercentage lovelaceAmount (owner2Fee1),lovelacePercentage lovelaceAmount (extraRecipient contractInfo)) 
                in 
                  Ada.fromValue (valuePaidTo txInfo owner1PubKeyHash) >= Ada.lovelaceOf amount1 && -- expected owner1 to receive right amount
                  Ada.fromValue (valuePaidTo txInfo owner2PubKeyHash) >= Ada.lovelaceOf amount2 && -- expected owner2 to receive right amount
                  Ada.fromValue (valuePaidTo txInfo tradeRecipient) >= Ada.lovelaceOf (lovelaceAmount - amount1 - amount2 - amount3) -- expected trade recipient to receive right amount
            | lovelaceAmount > 400000000 = let (amount1, amount2) = (lovelacePercentage lovelaceAmount (owner1Fee2),lovelacePercentage lovelaceAmount (owner2Fee1))
                in 
                  Ada.fromValue (valuePaidTo txInfo owner1PubKeyHash) >= Ada.lovelaceOf amount1 && -- expected owner1 to receive right amount
                  Ada.fromValue (valuePaidTo txInfo owner2PubKeyHash) >= Ada.lovelaceOf amount2 && -- expected owner2 to receive right amount
                  Ada.fromValue (valuePaidTo txInfo tradeRecipient) >= Ada.lovelaceOf (lovelaceAmount - amount1 - amount2) -- expected trade recipient to receive right amount
            | otherwise = let amount1 = lovelacePercentage lovelaceAmount (owner1Fee3)
                in
                  Ada.fromValue (valuePaidTo txInfo owner1PubKeyHash) >= Ada.lovelaceOf amount1 && -- expected owner1 to receive right amount
                  Ada.fromValue (valuePaidTo txInfo tradeRecipient) >= Ada.lovelaceOf (lovelaceAmount - amount1) -- expected trade recipient to receive right amount
          
        lovelacePercentage :: Integer -> Integer -> Integer
        lovelacePercentage am p = (am * 10) `divide` p


        outputInfo :: TxOut -> (Value, TradeDatum)
        outputInfo o = case txOutAddress o of
            Address (ScriptCredential _) _  -> case txOutDatumHash o of
                Just h -> case findDatum h txInfo of
                    Just (Datum d) ->  case PlutusTx.fromBuiltinData d of
                        Just b -> (txOutValue o, b)

        policyBidLength :: Value -> Integer
        policyBidLength v = length $ policyAssets v (policyBid contractInfo)

        containsPolicyBidNFT :: Value -> BuiltinByteString -> Bool
        containsPolicyBidNFT v tn = valueOf v (policyBid contractInfo) (TokenName ((prefixSpaceBudBid contractInfo) <> tn)) >= 1

        containsSpaceBudNFT :: Value -> BuiltinByteString -> Bool
        containsSpaceBudNFT v tn = valueOf v (policySpaceBudz contractInfo) (TokenName ((prefixSpaceBud contractInfo) <> tn)) >= 1


        scriptInputValue :: Value
        scriptInputValue =
            let
                isScriptInput i = case txOutAddress (txInInfoResolved i) of
                    Address (ScriptCredential _) _ -> True
                    _ -> False
                xs = [i | i <- txInfoInputs txInfo, isScriptInput i]
            in
                case xs of
                    [i] -> txOutValue (txInInfoResolved i)
            

        scriptOutputValue :: Value
        scriptOutputDatum :: TradeDatum
        (scriptOutputValue, scriptOutputDatum) = case getContinuingOutputs context of
            [o] -> outputInfo o

        -- 2 outputs possible because of distribution of inital bid NFT tokens and only applies if datum is StartBid
        correctStartBidOutputs :: Bool
        correctStartBidOutputs = if policyBidLength scriptInputValue > 1 
            then 
                case getContinuingOutputs context of
                    [o1, o2] -> let (info1, info2) = (outputInfo o1, outputInfo o2) in
                                case info1 of
                                    (v1, StartBid) -> 
                                        policyBidLength scriptInputValue - 1 == policyBidLength v1 && -- expected correct policyBid NFTs amount in output
                                        case info2 of
                                            (v2, Bid details) ->
                                                containsPolicyBidNFT v2 (budId details) && -- expected policyBid NFT in output
                                                getLovelace (Ada.fromValue v2) >= minPrice contractInfo && -- expected at least minPrice bid
                                                requestedAmount details == 1 -- expeced correct output datum amount
                                    (v1, Bid details) -> 
                                        containsPolicyBidNFT v1 (budId details) && -- expected policyBid NFT in output
                                        getLovelace (Ada.fromValue v1) >= minPrice contractInfo && -- expected at least minPrice bid
                                        requestedAmount details == 1 && -- expeced correct output datum amount
                                        case info2 of
                                            (v2, StartBid) -> 
                                                policyBidLength scriptInputValue - 1 == policyBidLength v2 -- expect correct policyBid NFTs amount in output
            else
                case getContinuingOutputs context of
                    [o] -> let (value, datum) = outputInfo o in case datum of
                            (Bid details) ->
                                containsPolicyBidNFT value (budId details) && -- expected policyBid NFT in output
                                getLovelace (Ada.fromValue value) >= minPrice contractInfo && -- expected at least minPrice bid
                                requestedAmount details == 1 -- expeced correct output datum amount

        

      
data Trade
instance Scripts.ValidatorTypes Trade where
    type instance RedeemerType Trade = TradeAction
    type instance DatumType Trade = TradeDatum

tradeInstance :: Scripts.TypedValidator Trade
tradeInstance = Scripts.mkTypedValidator @Trade
    ($$(PlutusTx.compile [|| tradeValidate ||]) `PlutusTx.applyCode` PlutusTx.liftCode contractInfo)
    $$(PlutusTx.compile [|| wrap ||])
  where
    wrap = Scripts.wrapValidator @TradeDatum @TradeAction

tradeValidator :: Validator
tradeValidator = Scripts.validatorScript tradeInstance


tradeAddress :: Ledger.Address
tradeAddress = scriptAddress tradeValidator

-- Types

PlutusTx.makeIsDataIndexed ''ContractInfo [('ContractInfo , 0)]
PlutusTx.makeLift ''ContractInfo

PlutusTx.makeIsDataIndexed ''TradeDetails [ ('TradeDetails, 0)]
PlutusTx.makeLift ''TradeDetails

PlutusTx.makeIsDataIndexed ''TradeDatum [ ('StartBid, 0)
                                        , ('Bid,   1)
                                        , ('Offer, 2)
                                        ]
PlutusTx.makeLift ''TradeDatum

PlutusTx.makeIsDataIndexed ''TradeAction [ ('Buy,       0)
                                         , ('Sell,      1)
                                         , ('BidHigher, 2)
                                         , ('Cancel,    3)
                                        ]
PlutusTx.makeLift ''TradeAction



-- Off-Chain

containsSpaceBudNFT :: Value -> BuiltinByteString -> Bool
containsSpaceBudNFT v tn = valueOf v (policySpaceBudz contractInfo) (TokenName ((prefixSpaceBud contractInfo) <> tn)) >= 1

containsPolicyBidNFT :: Value -> BuiltinByteString -> Bool
containsPolicyBidNFT v tn = valueOf v (policyBid contractInfo) (TokenName ((prefixSpaceBudBid contractInfo) <> tn)) >= 1

policyAssets :: Value -> CurrencySymbol -> [(CurrencySymbol, TokenName, Integer)]
policyAssets v cs = P.filter (\(cs',_,am) -> cs == cs' && am == 1) (flattenValue v)

policyBidLength :: Value -> Integer
policyBidLength v = length $ policyAssets v (policyBid contractInfo)

policyBidRemaining :: Value -> TokenName -> Value
policyBidRemaining v tn = convert (P.filter (\(cs',tn',am) -> (policyBid contractInfo) == cs' && am == 1 && tn /= tn' ) (flattenValue v))
    where convert [] = mempty
          convert ((cs,tn,am):t) = Value.singleton cs tn am <> convert t

data TradeParams = TradeParams
    { id :: !BuiltinByteString
    , amount :: !Integer
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

type TradeSchema = Endpoint "offer" TradeParams
        .\/ Endpoint "buy" TradeParams
        .\/ Endpoint "cancelOffer" TradeParams
        .\/ Endpoint "cancelBid" TradeParams
        .\/ Endpoint "init" ()
        .\/ Endpoint "bid" TradeParams
        .\/ Endpoint "sell" TradeParams

trade :: AsContractError e => Contract () TradeSchema e ()
trade = selectList [init, offer, buy, cancelOffer, bid, sell, cancelBid] >> trade

endpoints :: AsContractError e => Contract () TradeSchema e ()
endpoints = trade

init :: AsContractError e => Promise () TradeSchema e ()
init = endpoint @"init" @() $ \() -> do
    let tx = mustPayToTheScript StartBid (Value.singleton (policyBid contractInfo) (TokenName "SpaceBudBid0") 1 <> Value.singleton (policyBid contractInfo) (TokenName "SpaceBudBid1") 1 <> Value.singleton (policyBid contractInfo) (TokenName "SpaceBudBid2") 1) 
    void $ submitTxConstraints tradeInstance tx

bid :: AsContractError e => Promise () TradeSchema e ()
bid = endpoint @"bid" @TradeParams $ \(TradeParams{..}) -> do
    utxos <- utxoAt tradeAddress
    pkh <- pubKeyHash <$> Plutus.Contract.ownPubKey
    let bidUtxo = [ (oref, o, getTradeDatum o, txOutValue $ txOutTxOut o) | (oref, o) <- Map.toList utxos, case getTradeDatum o of (StartBid) -> containsPolicyBidNFT (txOutValue $ txOutTxOut o) id; (Bid details) -> budId details == id && containsPolicyBidNFT (txOutValue $ txOutTxOut o) id; _ -> False]
    let bidDatum = Bid TradeDetails {budId = id, requestedAmount = 1, tradeOwner = pkh}
    case bidUtxo of
        [(oref, o, StartBid, value)] -> do
            if amount < minPrice contractInfo then traceError "amount too small" else if policyBidLength value > 1 then do
                let utxoMap = Map.fromList [(oref,o)]
                    tx = collectFromScript utxoMap BidHigher <> 
                        mustPayToTheScript bidDatum (Ada.lovelaceValueOf (amount) <> Value.singleton (policyBid contractInfo) (TokenName ("SpaceBudBid" <> id)) 1) <>
                        mustPayToTheScript StartBid (policyBidRemaining value (TokenName ("SpaceBudBid" <> id)))
                void $ submitTxConstraintsSpending tradeInstance utxos tx
            else do
                let utxoMap = Map.fromList [(oref,o)]
                    tx = collectFromScript utxoMap BidHigher <> 
                        mustPayToTheScript bidDatum (Ada.lovelaceValueOf (amount) <> Value.singleton (policyBid contractInfo) (TokenName ("SpaceBudBid" <> id)) 1)
                void $ submitTxConstraintsSpending tradeInstance utxos tx
        [(oref, o, Bid details, value)] -> do
            if amount < bidStep contractInfo + getLovelace (Ada.fromValue value) then traceError "amount too small" else do
                let utxoMap = Map.fromList [(oref,o)]
                    tx = collectFromScript utxoMap BidHigher <> 
                        mustPayToTheScript bidDatum (Ada.lovelaceValueOf (amount) <> Value.singleton (policyBid contractInfo) (TokenName ("SpaceBudBid" <> id)) 1) <>
                        mustPayToPubKey (tradeOwner details) (Ada.toValue (Ada.fromValue value))
                void $ submitTxConstraintsSpending tradeInstance utxos tx
        _ -> traceError "expected only one output"


sell :: AsContractError e => Promise () TradeSchema e ()
sell = endpoint @"sell" @TradeParams $ \(TradeParams{..}) -> do
    utxos <- utxoAt tradeAddress
    pkh <- pubKeyHash <$> Plutus.Contract.ownPubKey
    let bidUtxo = [ (oref, o, getTradeDatum o, txOutValue $ txOutTxOut o) | (oref, o) <- Map.toList utxos, case getTradeDatum o of (Bid details) -> id == budId details && containsPolicyBidNFT (txOutValue $ txOutTxOut o) id; _ -> False]
    case bidUtxo of
        [(oref, o, Bid details, value)] -> do
            let (owner1PubKeyHash, owner1Fee1, owner1Fee2, owner1Fee3) = owner1 contractInfo
            let lovelace = getLovelace $ Ada.fromValue value
            let (traderAmount, ownerAmount) = let fee = (lovelace * 10) `Haskell.div` owner1Fee3 in (lovelace - fee, fee)
            let utxoMap = Map.fromList [(oref,o)]
            let tx = collectFromScript utxoMap Sell <> 
                    mustPayToPubKey (owner1PubKeyHash) (Ada.lovelaceValueOf ownerAmount) <>
                    mustPayToPubKey (pkh) (Ada.lovelaceValueOf traderAmount) <>
                    mustPayToPubKey (tradeOwner details) (Value.singleton (policySpaceBudz contractInfo) (TokenName ("SpaceBud" <> id)) 1) <>
                    mustPayToTheScript StartBid (Value.singleton (policyBid contractInfo) (TokenName ("SpaceBudBid" <> id)) 1)
            void $ submitTxConstraintsSpending tradeInstance utxos tx
        _ -> traceError "expected only one output"


offer :: AsContractError e => Promise () TradeSchema e ()
offer = endpoint @"offer" @TradeParams $ \(TradeParams{..}) -> do
    pkh <- pubKeyHash <$> Plutus.Contract.ownPubKey
    let tradeDatum = Offer TradeDetails {budId = id, requestedAmount = amount, tradeOwner = pkh}
        tx = mustPayToTheScript tradeDatum (Value.singleton (policySpaceBudz contractInfo) (TokenName ("SpaceBud" <> id)) 1)
    void $ submitTxConstraints tradeInstance tx


buy :: AsContractError e => Promise () TradeSchema e ()
buy = endpoint @"buy" @TradeParams $ \(TradeParams{..}) -> do
    utxos <- utxoAt tradeAddress
    pkh <- pubKeyHash <$> Plutus.Contract.ownPubKey
    let offerUtxo = [ (oref, o, getTradeDatum o, txOutValue $ txOutTxOut o) | (oref, o) <- Map.toList utxos, case getTradeDatum o of (Offer details) -> id == budId details && containsSpaceBudNFT (txOutValue $ txOutTxOut o) id; _ -> False]
    case offerUtxo of
        [(oref, o, Offer details, value)] -> do
            let (owner1PubKeyHash, owner1Fee1, owner1Fee2, owner1Fee3) = owner1 contractInfo
            let (traderAmount, ownerAmount) = let fee = (requestedAmount details * 10) `Haskell.div` owner1Fee3 in (requestedAmount details - fee, fee)
            let utxoMap = Map.fromList [(oref,o)]
            let tx = collectFromScript utxoMap Buy <> 
                    mustPayToPubKey (owner1PubKeyHash) (Ada.lovelaceValueOf ownerAmount) <>
                    mustPayToPubKey (tradeOwner details) (Ada.lovelaceValueOf traderAmount) <>
                    mustPayToPubKey (pkh) (Value.singleton (policySpaceBudz contractInfo) (TokenName ("SpaceBud" <> id)) 1)
            void $ submitTxConstraintsSpending tradeInstance utxos tx
        _ -> traceError "expected only one output"


cancelOffer :: AsContractError e => Promise () TradeSchema e ()
cancelOffer = endpoint @"cancelOffer" @TradeParams $ \(TradeParams{..}) -> do
    utxos <- utxoAt tradeAddress
    pkh <- pubKeyHash <$> Plutus.Contract.ownPubKey
    let offerUtxo = [ (oref, o, getTradeDatum o, txOutValue $ txOutTxOut o) | (oref, o) <- Map.toList utxos, case getTradeDatum o of (Offer details) -> id == budId details && containsSpaceBudNFT (txOutValue $ txOutTxOut o) id; _ -> False]
    case offerUtxo of
        [(oref, o, Offer details, value)] -> do
            let utxoMap = Map.fromList [(oref,o)]
                tx = collectFromScript utxoMap (Cancel) <> 
                    mustPayToPubKey (pkh) value
            void $ submitTxConstraintsSpending tradeInstance utxos tx
        _ -> traceError "expected only one output"

cancelBid :: AsContractError e => Promise () TradeSchema e ()
cancelBid = endpoint @"cancelBid" @TradeParams $ \(TradeParams{..}) -> do
    utxos <- utxoAt tradeAddress
    pkh <- pubKeyHash <$> Plutus.Contract.ownPubKey
    let bidUtxo = [ (oref, o, getTradeDatum o, txOutValue $ txOutTxOut o) | (oref, o) <- Map.toList utxos, case getTradeDatum o of (Bid details) -> id == budId details && containsPolicyBidNFT (txOutValue $ txOutTxOut o) id; _ -> False]
    case bidUtxo of
        [(oref, o, Bid details, value)] -> do
            let utxoMap = Map.fromList [(oref,o)]
                tx = collectFromScript utxoMap (Cancel) <> 
                    mustPayToPubKey (tradeOwner details) (Ada.toValue (Ada.fromValue value)) <>
                    mustPayToTheScript StartBid (Value.singleton (policyBid contractInfo) (TokenName ("SpaceBudBid" <> id)) 1)
            void $ submitTxConstraintsSpending tradeInstance utxos tx
        _ -> traceError "expected only one output"

getTradeDatum :: TxOutTx -> TradeDatum
getTradeDatum o = case txOutDatum (txOutTxOut o) of
    Just h -> do
        let [(_,datum)] = P.filter (\(h',_) -> h == h') (Map.toList (txData (txOutTxTx o)))
        let parsedDatum = PlutusTx.fromBuiltinData (getDatum datum) :: Maybe TradeDatum
        case parsedDatum of
            Just b -> b
            _ -> traceError "expected datum"
    _ -> traceError "expected datum"





mkSchemaDefinitions ''TradeSchema
spacebud0 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBud0" :| [])
spacebud1 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBud1" :| [])
spacebud2 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBud2" :| [])
spacebud3 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBud3" :| [])

spacebudBid0 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBudBid0" :| [])
spacebudBid1 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBudBid1" :| [])
spacebudBid2 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBudBid2" :| [])
spacebudBid3 = KnownCurrency (ValidatorHash "f") "Token" (TokenName "SpaceBudBid3" :| [])



mkKnownCurrencies ['spacebud0,'spacebud1, 'spacebud2, 'spacebud3, 'spacebudBid0,'spacebudBid1,'spacebudBid2,'spacebudBid3]

-- Serialization

{-
    As a Script
-}

tradeScript :: Plutus.Script
tradeScript = Plutus.unValidatorScript tradeValidator

{-
    As a Short Byte String
-}

tradeSBS :: SBS.ShortByteString
tradeSBS =  SBS.toShort . LBS.toStrict $ serialise tradeScript

{-
    As a Serialised Script
-}

tradeSerialised :: PlutusScript PlutusScriptV1
tradeSerialised = PlutusScriptSerialised tradeSBS