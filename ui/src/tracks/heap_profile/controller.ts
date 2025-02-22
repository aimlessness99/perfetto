// Copyright (C) 2019 The Android Open Source Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import {NUM, STR} from '../../common/query_result';
import {
  TrackController,
  trackControllerRegistry,
} from '../../controller/track_controller';

import {
  Config,
  Data,
  HEAP_PROFILE_TRACK_KIND,
} from './common';

class HeapProfileTrackController extends TrackController<Config, Data> {
  static readonly kind = HEAP_PROFILE_TRACK_KIND;
  async onBoundsChange(start: number, end: number, resolution: number):
      Promise<Data> {
    if (this.config.upid === undefined) {
      return {
        start,
        end,
        resolution,
        length: 0,
        tsStarts: new Float64Array(),
        types: new Array<string>(),
      };
    }
    const queryRes = await this.query(`
    select * from
    (select distinct(ts) as ts, 'native' as type from heap_profile_allocation
     where upid = ${this.config.upid}
        union
        select distinct(graph_sample_ts) as ts, 'graph' as type from
        heap_graph_object
        where upid = ${this.config.upid}) order by ts`);
    const numRows = queryRes.numRows();
    const data: Data = {
      start,
      end,
      resolution,
      length: numRows,
      tsStarts: new Float64Array(numRows),
      types: new Array<string>(numRows),
    };

    const it = queryRes.iter({ts: NUM, type: STR});
    for (let row = 0; it.valid(); it.next(), row++) {
      data.tsStarts[row] = it.ts;
      data.types[row] = it.type;
    }
    return data;
  }
}

trackControllerRegistry.register(HeapProfileTrackController);
