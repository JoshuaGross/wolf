{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE ConstraintKinds   #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.AWS.Flow
  ( register
  , execute
  , act
  , decide
  , runFlowT
  , throwStringError
  , hoistStringEither
  , maybeToFlowError
  , Uid
  , Name
  , Version
  , Queue
  , Token
  , Timeout
  , Metadata
  , Artifact
  , FlowConfig (..)
  , FlowEnv (..)
  , FlowError
  , FlowT
  , MonadFlow
  , Task (..)
  , Timer (..)
  , Start (..)
  , Spec (..)
  , End (..)
  , Plan (..)
  ) where

import Control.Lens               ( (^.) )
import Control.Monad              ( foldM, forM_ )
import Control.Monad.Logger       ( logInfoN )
import Control.Monad.Reader       ( asks )
import Data.List                  ( find )
import Formatting                 ( (%), sformat )
import Formatting.ShortFormatters ( st )
import Network.AWS.SWF
import Network.AWS.Flow.Internal
import Network.AWS.Flow.S3
import Network.AWS.Flow.SWF
import Network.AWS.Flow.Types
import Safe                       ( headMay, tailMay )


-- Interface

register :: MonadFlow m => Plan -> m [()]
register Plan{..} = do
  logInfoN "event=register\n"
  r <- registerDomainAction
  s <- registerWorkflowTypeAction
         (tskName $ strtTask plnStart)
         (tskVersion $ strtTask plnStart)
         (tskTimeout $ strtTask plnStart)
  foldM go [s, r] plnSpecs where
    go rs Work{..} = do
      r <- registerActivityTypeAction
             (tskName wrkTask)
             (tskVersion wrkTask)
             (tskTimeout wrkTask)
      return (r : rs)
    go rs Sleep{..} = return rs


execute :: MonadFlow m => Task -> Metadata -> m ()
execute Task{..} input = do
  uid <- newUid
  logInfoN $ sformat ("event=execute uid=" % st % "\n") uid
  startWorkflowExecutionAction uid tskName tskVersion tskQueue input

act :: MonadFlow m => Queue -> (Uid -> Metadata -> m (Metadata, [Artifact])) -> m ()
act queue action = do
  logInfoN "event=act\n"
  (token, uid, input) <- pollForActivityTaskAction queue
  logInfoN $ sformat ("event=act-start uid=" % st % "\n") uid
  (output, artifacts) <- action uid input
  logInfoN $ sformat ("event=act-finish uid=" % st % "\n") uid
  forM_ artifacts putObjectAction
  respondActivityTaskCompletedAction token output

decide :: MonadFlow m => Plan -> m ()
decide plan@Plan{..} = do
  logInfoN "event=decide\n"
  (token', events) <- pollForDecisionTaskAction (tskQueue $ strtTask plnStart)
  token <- maybeToFlowError "No Token" token'
  logger <- asks feLogger
  logInfoN "event=decide-select\n"
  decisions <- runDecide logger plan events select
  respondDecisionTaskCompletedAction token decisions

-- Helpers

nextEvent :: MonadDecide m => [EventType] -> m HistoryEvent
nextEvent ets = do
  events <- asks deEvents
  maybeToFlowError "No Next Event" $ flip find events $ \e ->
    e ^. heEventType `elem` ets

workNext :: MonadDecide m => Name -> m (Maybe Spec)
workNext name = do
  specs <- asks (plnSpecs . dePlan)
  return $ tailMay (dropWhile p specs) >>= headMay where
    p Work{..} = tskName wrkTask /= name
    p _ = True

sleepNext :: MonadDecide m => Name -> m (Maybe Spec)
sleepNext name = do
  specs <- asks (plnSpecs . dePlan)
  return $ tailMay (dropWhile p specs) >>= headMay where
    p Sleep{..} = tmrName slpTimer /= name
    p _ = True

select :: MonadDecide m => m [Decision]
select = do
  event <- nextEvent [ WorkflowExecutionStarted
                     , ActivityTaskCompleted
                     , TimerFired
                     , StartChildWorkflowExecutionInitiated ]
  case event ^. heEventType of
    WorkflowExecutionStarted             -> start event
    ActivityTaskCompleted                -> completed event
    TimerFired                           -> timer event
    StartChildWorkflowExecutionInitiated -> child
    _                                    -> throwStringError "Unknown Select Event"

start :: MonadDecide m => HistoryEvent -> m [Decision]
start event = do
  input <- maybeToFlowError "No Start Information" $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  specs <- asks (plnSpecs . dePlan)
  schedule input $ headMay specs

completed :: MonadDecide m => HistoryEvent -> m [Decision]
completed event = do
  findEvent <- asks deFindEvent
  (input, name) <- maybeToFlowError "No Completed Information" $ do
    attrs <- event ^. heActivityTaskCompletedEventAttributes
    event' <- findEvent $ attrs ^. atceaScheduledEventId
    attrs' <- event' ^. heActivityTaskScheduledEventAttributes
    return (attrs ^. atceaResult, attrs' ^. atseaActivityType ^. atName)
  next <- workNext name
  schedule input next

timer :: MonadDecide m => HistoryEvent -> m [Decision]
timer event = do
  findEvent <- asks deFindEvent
  name <- maybeToFlowError "No Timer Information" $ do
    attrs <- event ^. heTimerFiredEventAttributes
    event' <- findEvent $ attrs ^. tfeaStartedEventId
    attrs' <- event' ^. heTimerStartedEventAttributes
    attrs' ^. tseaControl
  event' <- nextEvent [WorkflowExecutionStarted, ActivityTaskCompleted]
  case event' ^. heEventType of
    WorkflowExecutionStarted -> timerStart event' name
    ActivityTaskCompleted    -> timerCompleted event' name
    _                        -> throwStringError "Unknown Timer Event"

timerStart :: MonadDecide m => HistoryEvent -> Name -> m [Decision]
timerStart event name = do
  input <- maybeToFlowError "No Timer Start Information" $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  next <- sleepNext name
  schedule input next

timerCompleted :: MonadDecide m => HistoryEvent -> Name -> m [Decision]
timerCompleted event name = do
  input <- maybeToFlowError "No Timer Completed Information" $ do
    attrs <- event ^. heActivityTaskCompletedEventAttributes
    return $ attrs ^. atceaResult
  next <- sleepNext name
  schedule input next

schedule :: MonadDecide m => Metadata -> Maybe Spec -> m [Decision]
schedule input = maybe (scheduleEnd input) (scheduleSpec input)

scheduleSpec :: MonadDecide m => Metadata -> Spec -> m [Decision]
scheduleSpec input spec = do
  uid <- newUid
  case spec of
    Work{..} ->
      return [scheduleActivityTaskDecision uid
               (tskName wrkTask)
               (tskVersion wrkTask)
               (tskQueue wrkTask)
               input]
    Sleep{..} ->
      return [startTimerDecision uid
               (tmrName slpTimer)
               (tmrTimeout slpTimer)]

scheduleEnd :: MonadDecide m => Metadata -> m [Decision]
scheduleEnd input = do
  end <- asks (plnEnd . dePlan)
  case end of
    Stop -> return [completeWorkflowExecutionDecision input]
    Continue -> scheduleContinue

scheduleContinue :: MonadDecide m => m [Decision]
scheduleContinue = do
  event <- nextEvent [WorkflowExecutionStarted]
  input <- maybeToFlowError "No Continue Start Information" $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  uid <- newUid
  task <- asks (strtTask . plnStart . dePlan)
  return [startChildWorkflowExecutionDecision uid
           (tskName task)
           (tskVersion task)
           (tskQueue task)
           input]

child :: MonadDecide m => m [Decision]
child = do
  event <- nextEvent [WorkflowExecutionStarted, ActivityTaskCompleted]
  case event ^. heEventType of
    WorkflowExecutionStarted -> childStart event
    ActivityTaskCompleted    -> childCompleted event
    _                        -> throwStringError "Unknown Child Event"

childStart :: MonadDecide m => HistoryEvent -> m [Decision]
childStart event = do
  input <- maybeToFlowError "No Child Start Information" $ do
    attrs <- event ^. heWorkflowExecutionStartedEventAttributes
    return $ attrs ^. weseaInput
  return [completeWorkflowExecutionDecision input]

childCompleted :: MonadDecide m => HistoryEvent -> m [Decision]
childCompleted event = do
  input <- maybeToFlowError "No Child Completed Information" $ do
    attrs <- event ^. heActivityTaskCompletedEventAttributes
    return $ attrs ^. atceaResult
  return [completeWorkflowExecutionDecision input]

