/*
 * Copyright (C) 2023 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "src/trace_processor/importers/etw/etw_module.h"
#include "perfetto/base/build_config.h"
#include "perfetto/trace_processor/trace_blob_view.h"
#include "src/trace_processor/importers/etw/etw_tokenizer.h"

#include "protos/perfetto/trace/trace_packet.pbzero.h"

namespace perfetto {
namespace trace_processor {

using perfetto::protos::pbzero::TracePacket;

EtwModule::EtwModule(TraceProcessorContext* context) : tokenizer_(context) {
  RegisterForField(TracePacket::kEtwEventsFieldNumber, context);
}

ModuleResult EtwModule::TokenizePacket(
    const protos::pbzero::TracePacket::Decoder& decoder,
    TraceBlobView* packet,
    int64_t /*packet_timestamp*/,
    PacketSequenceState* seq_state,
    uint32_t field_id) {
  switch (field_id) {
    case TracePacket::kEtwEventsFieldNumber: {
      auto etw_field = decoder.etw_events();
      tokenizer_.TokenizeEtwBundle(
          packet->slice(etw_field.data, etw_field.size), seq_state);
      return ModuleResult::Handled();
    }
  }
  return ModuleResult::Ignored();
}

}  // namespace trace_processor
}  // namespace perfetto
