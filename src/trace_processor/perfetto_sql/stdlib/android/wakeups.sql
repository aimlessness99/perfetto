-- Copyright 2025 The Android Open Source Project
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

include perfetto module android.suspend;

-- Table of parsed wakeup / suspend failure events with suspend backoff.
--
-- Certain wakeup events may have multiple causes. When this occurs we
-- split those causes into multiple rows in this table with the same ts
-- and raw_wakeup values.
CREATE PERFETTO TABLE android_wakeups(
  -- Timestamp.
  ts TIMESTAMP,
  -- Duration for which we blame the wakeup for wakefulness. This is the
  -- suspend backoff duration if one exists, or the lesser of (5 seconds,
  -- time to next suspend event).
  dur DURATION,
  -- Original wakeup string from the kernel.
  raw_wakeup STRING,
  -- Wakeup attribution, as determined on device. May be absent.
  on_device_attribution STRING,
  -- One of 'normal' (device woke from sleep), 'abort_pending' (suspend failed
  -- due to a wakeup that was scheduled by a device during the suspend
  -- process), 'abort_last_active' (suspend failed, listing the last active
  -- device) or 'abort_other' (suspend failed for another reason).
  type STRING,
  -- Individual wakeup cause. Usually the name of the device that cause the
  -- wakeup, or the raw message in the 'abort_other' case.
  item STRING,
  -- 'good' or 'bad'. 'bad' means failed or short such that suspend backoff
  -- is triggered.
  suspend_quality STRING,
  -- 'new', 'continue' or NULL. Set if suspend backoff is triggered.
  backoff_state STRING,
  -- 'short', 'failed' or NULL. Set if suspend backoff is triggered.
  backoff_reason STRING,
  -- Number of times suspend backoff has occured, or NULL. Set if suspend
  -- backoff is triggered.
  backoff_count LONG,
  -- Next suspend backoff duration, or NULL. Set if suspend backoff is
  -- triggered.
  backoff_millis LONG) AS
with wakeup_reason as (
    select
    ts,
    substr(i.name, 0, instr(i.name, ' ')) as id_timestamp,
    substr(i.name, instr(i.name, ' ') + 1) as raw_wakeup
    from track t join instant i on t.id = i.track_id
    where t.name = 'wakeup_reason'
),
wakeup_attribution as (
    select
    substr(i.name, 0, instr(i.name, ' ')) as id_timestamp,
    substr(i.name, instr(i.name, ' ') + 1) as on_device_attribution
    from track t join instant i on t.id = i.track_id
    where t.name = 'wakeup_attribution'
),
step1 as(
  select
    ts,
    raw_wakeup,
    on_device_attribution,
    null as raw_backoff
  from wakeup_reason r
    left outer join wakeup_attribution using(id_timestamp)
  union all
  select
    ts,
    null as raw_wakeup,
    null as on_device_attribution,
    i.name as raw_backoff
  from track t join instant i on t.id = i.track_id
  where t.name = 'suspend_backoff'
),
step2 as (
  select
    ts,
    raw_wakeup,
    on_device_attribution,
    lag(raw_backoff) over (order by ts) as raw_backoff
  from step1
),
step3 as (
  select
    ts,
    raw_wakeup,
    on_device_attribution,
    str_split(raw_backoff, ' ', 0) as suspend_quality,
    str_split(raw_backoff, ' ', 1) as backoff_state,
    str_split(raw_backoff, ' ', 2) as backoff_reason,
    cast(str_split(raw_backoff, ' ', 3) as int) as backoff_count,
    cast(str_split(raw_backoff, ' ', 4) as int) as backoff_millis,
    false as suspend_end
  from step2
  where raw_wakeup is not null
  union all
  select
    ts,
    null as raw_wakeup,
    null as on_device_attribution,
    null as suspend_quality,
    null as backoff_state,
    null as backoff_reason,
    null as backoff_count,
    null as backoff_millis,
    true as suspend_end
  from android_suspend_state
  where power_state = 'suspended'
),
step4 as (
  select
    ts,
    case suspend_quality
      when 'good' then
        min(
          lead(ts, 1, ts + 5e9) over (order by ts) - ts,
          5e9
        )
      when 'bad' then backoff_millis * 1000000
      else 0
    end as dur,
    raw_wakeup,
    on_device_attribution,
    suspend_quality,
    backoff_state,
    backoff_reason,
    backoff_count,
    backoff_millis,
    suspend_end
  from step3
),
step5 as (
  select
    ts,
    dur,
    raw_wakeup,
    on_device_attribution,
    suspend_quality,
    backoff_state,
    backoff_reason,
    backoff_count,
    backoff_millis
  from step4
  where not suspend_end
),
step6 as (
  select
    ts,
    dur,
    raw_wakeup,
    on_device_attribution,
    suspend_quality,
    backoff_state,
    backoff_reason,
    backoff_count,
    backoff_millis,
    case
      when raw_wakeup glob 'Abort: Pending Wakeup Sources: *' then 'abort_pending'
      when raw_wakeup glob 'Abort: Last active Wakeup Source: *' then 'abort_last_active'
      when raw_wakeup glob 'Abort: *' then 'abort_other'
      else 'normal'
    end as type,
    case
      when raw_wakeup glob 'Abort: Pending Wakeup Sources: *' then substr(raw_wakeup, 32)
      when raw_wakeup glob 'Abort: Last active Wakeup Source: *' then substr(raw_wakeup, 35)
      when raw_wakeup glob 'Abort: *' then substr(raw_wakeup, 8)
      else raw_wakeup
    end as main,
    case
      when raw_wakeup glob 'Abort: Pending Wakeup Sources: *' then ' '
      when raw_wakeup glob 'Abort: *' then 'no delimiter needed'
      else ':'
    end as delimiter
  from step5
),
step7 as (
  select
    ts,
    dur,
    raw_wakeup,
    on_device_attribution,
    suspend_quality,
    backoff_state,
    backoff_reason,
    backoff_count,
    backoff_millis,
    type,
    str_split(main, delimiter, 0) as item_0,
    str_split(main, delimiter, 1) as item_1,
    str_split(main, delimiter, 2) as item_2,
    str_split(main, delimiter, 3) as item_3
  from step6
),
step8 as (
  select ts, dur, raw_wakeup, on_device_attribution, suspend_quality, backoff_state, backoff_reason, backoff_count, backoff_millis, type, item_0 as item from step7
  union all
  select ts, dur, raw_wakeup, on_device_attribution, suspend_quality, backoff_state, backoff_reason, backoff_count, backoff_millis, type, item_1 as item from step7 where item_1 is not null
  union all
  select ts, dur, raw_wakeup, on_device_attribution, suspend_quality, backoff_state, backoff_reason, backoff_count, backoff_millis, type, item_2 as item from step7 where item_2 is not null
  union all
  select ts, dur, raw_wakeup, on_device_attribution, suspend_quality, backoff_state, backoff_reason, backoff_count, backoff_millis, type, item_3 as item from step7 where item_3 is not null
)
select
  ts,
  cast_int!(dur) as dur,
  raw_wakeup,
  on_device_attribution,
  type,
  case when type = 'normal' then ifnull(str_split(item, ' ', 1), item) else item end as item,
  suspend_quality,
  backoff_state,
  ifnull(backoff_reason, 'none') as backoff_reason,
  backoff_count,
  backoff_millis
from step8;
