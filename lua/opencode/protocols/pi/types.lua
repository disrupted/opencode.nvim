---@class OpencodePiSessionFact
---@field id string
---@field title string
---@field location OpencodeLocation
---@field time {created: number, updated: number}
---@field path string Session file on disk

---@class OpencodePiMessage Native message as stored in session JSONL and returned by `get_messages`
---@field role 'user'|'assistant'|'toolResult'|string
---@field timestamp? number Milliseconds
---@field content? string|table[]
---@field toolCallId? string
---@field toolName? string
---@field isError? boolean
---@field provider? string
---@field model? string
---@field stopReason? string
---@field errorMessage? string
---@field usage? table

---@class OpencodePiState Result of the `get_state` RPC
---@field sessionId? string
---@field sessionFile? string
---@field isStreaming? boolean

---@class OpencodePiClient
---@field process {start: fun(self: table): Promise<any>, is_running: fun(self: table): boolean, stop: fun(self: table)}
---@field get_state fun(self: OpencodePiClient): Promise<OpencodePiState>
---@field get_messages fun(self: OpencodePiClient): Promise<{messages: OpencodePiMessage[]}>
---@field switch_session fun(self: OpencodePiClient, path: string): Promise<{cancelled?: boolean}>
---@field new_session fun(self: OpencodePiClient): Promise<{cancelled?: boolean}>
---@field prompt fun(self: OpencodePiClient, message: string): Promise<any>
---@field abort fun(self: OpencodePiClient): Promise<any>

---@class OpencodePiConnection: OpencodeServer
---@field pi {session_id?: string} Pi runs one active session; it is tracked here because switching is a process command

return {}
