/*
 * Copyright (C) 2024 The Android Open Source Project
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

#include "src/trace_processor/importers/etm/target_memory.h"

#include <memory>
#include <optional>

#include "perfetto/base/logging.h"
#include "perfetto/ext/base/flat_hash_map.h"
#include "perfetto/public/compiler.h"
#include "perfetto/trace_processor/trace_blob_view.h"
#include "src/trace_processor/importers/common/address_range.h"
#include "src/trace_processor/importers/etm/mapping_version.h"
#include "src/trace_processor/importers/etm/virtual_address_space.h"
#include "src/trace_processor/storage/trace_storage.h"
#include "src/trace_processor/tables/metadata_tables_py.h"
#include "src/trace_processor/types/destructible.h"
#include "src/trace_processor/types/trace_processor_context.h"

namespace perfetto::trace_processor::etm {

// static
void TargetMemory::InitStorage(TraceProcessorContext* context) {
  PERFETTO_CHECK(context->storage->etm_target_memory() == nullptr);
  context->storage->set_etm_target_memory(
      std::unique_ptr<Destructible>(new TargetMemory(context)));
}

TargetMemory::TargetMemory(TraceProcessorContext* context)
    : storage_(context->storage.get()) {
  auto kernel = VirtualAddressSpace::Builder(context);
  base::FlatHashMap<UniquePid, VirtualAddressSpace::Builder> user;

  for (auto mmap = context->storage->mmap_record_table().IterateRows(); mmap;
       ++mmap) {
    std::optional<UniquePid> upid = mmap.upid();
    if (!upid) {
      kernel.AddMapping(mmap.row_reference());
      continue;
    }
    auto it = user.Find(*upid);
    if (!it) {
      it = user.Insert(*upid, VirtualAddressSpace::Builder(context)).first;
    }
    it->AddMapping(mmap.row_reference());
  }

  kernel_memory_ = std::move(kernel).Build();
  for (auto it = user.GetIterator(); it; ++it) {
    user_memory_.Insert(it.key(), std::move(it.value()).Build());
  }
}
TargetMemory::~TargetMemory() = default;

VirtualAddressSpace* TargetMemory::FindUserSpaceForTid(uint32_t tid) const {
  auto user_mem = tid_to_space_.Find(tid);
  if (PERFETTO_UNLIKELY(!user_mem)) {
    std::optional<UniquePid> upid = FindUpidForTid(tid);
    user_mem =
        tid_to_space_.Insert(tid, upid ? user_memory_.Find(*upid) : nullptr)
            .first;
  }

  return *user_mem;
}

std::optional<UniquePid> TargetMemory::FindUpidForTid(uint32_t tid) const {
  const auto& tread_table = storage_->thread_table();
  Query q;
  q.constraints = {tread_table.tid().eq(tid)};
  auto it = tread_table.FilterToIterator(q);
  if (!it) {
    return std::nullopt;
  }
  return it.upid();
}

const MappingVersion* TargetMemory::FindMapping(int64_t ts,
                                                uint32_t tid,
                                                uint64_t address) const {
  if (IsKernelAddress(address)) {
    return kernel_memory_.FindMapping(ts, address);
  }
  auto* vas = FindUserSpaceForTid(tid);
  if (!vas) {
    return nullptr;
  }
  return vas->FindMapping(ts, address);
}

const MappingVersion* TargetMemory::FindMapping(
    int64_t ts,
    uint32_t tid,
    const AddressRange& range) const {
  const MappingVersion* m = FindMapping(ts, tid, range.start());
  if (!m || range.end() > m->end()) {
    return nullptr;
  }
  return m;
}

}  // namespace perfetto::trace_processor::etm
