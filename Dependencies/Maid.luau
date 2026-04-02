--//!strict
--// Maid
--// Author: Quenty
--// Source: https://github.com/Quenty/NevermoreEngine/blob/version2/Modules/Shared/Events/Maid.lua
--// License: MIT (https://github.com/Quenty/NevermoreEngine/blob/version2/LICENSE.md)
--// This module has been modified for use in AeroGameFramework, and further modified for strict types and PascalCase.

--[[
	Maid = Maid.New()

	Maid:GiveTask(Task)
		> Task is an event connection, function, or instance/table with a 'Destroy' method

	Maid:GivePromise(TaskPromise)
	
	Maid:DoCleaning()
		> Alias for Destroy
	
	Maid:Destroy()
		> Goes through each task & disconnects events, destroys instances, and calls functions
--]]

export type Task = (() -> ()) | RBXScriptConnection | { Destroy: (...any) -> ...any } | Instance | any

export type Promise = {
	GetStatus: (self: Promise) -> string,
	Finally: (self: Promise, Callback: () -> ()) -> (),
	[any]: any,
}

export type Maid = typeof(setmetatable(
	{} :: {
		_Tasks: { [any]: Task },
		Shared: any?,
	},
	{} :: MaidClass
))

type MaidClass = {
	ClassName: string,
	__index: (self: Maid, Index: any) -> any,
	__newindex: (self: Maid, Index: any, NewTask: Task) -> (),
	New: () -> Maid,
	GiveTask: (self: Maid, Task: Task) -> number,
	GivePromise: (self: Maid, TaskPromise: Promise) -> Promise,
	DoCleaning: (self: Maid) -> (),
	Init: (self: Maid) -> (),
	Destroy: (self: Maid) -> (),
}

local Maid: MaidClass = {} :: MaidClass
Maid.ClassName = "Maid"

local PromiseModule: any

--- Returns a new Maid object
-- @constructor Maid.New()
-- @treturn Maid
function Maid.New(): Maid
	local self = setmetatable({
		_Tasks = {} :: { [any]: Task },
	}, Maid)

	return self :: Maid
end

--- Returns Maid[key] if not part of Maid metatable
-- @return Maid[key] value
function Maid:__index(Index: any): any
	if (Maid :: any)[Index] then
		return (Maid :: any)[Index]
	else
		return self._Tasks[Index]
	end
end

--- Add a task to clean up
-- @usage
-- Maid[key] = (function)         Adds a task to perform
-- Maid[key] = (event connection) Manages an event connection
-- Maid[key] = (Maid)             Maids can act as an event connection, allowing a Maid to have other maids to clean up.
-- Maid[key] = (Object)           Maids can cleanup objects with a `Destroy` method
-- Maid[key] = nil                Removes a named task. If the task is an event, it is disconnected. If it is an object,
--                                it is destroyed.
function Maid:__newindex(Index: any, NewTask: Task)
	if (Maid :: any)[Index] ~= nil then
		error(("'%s' is reserved"):format(tostring(Index)), 2)
	end

	local Tasks = self._Tasks
	local OldTask = Tasks[Index]
	Tasks[Index] = NewTask

	if OldTask then
		if type(OldTask) == "function" then
			OldTask()
		elseif typeof(OldTask) == "RBXScriptConnection" then
			OldTask:Disconnect()
		elseif (OldTask :: any).Destroy then
			(OldTask :: any):Destroy()
		end
	end
end

--- Same as indexing, but uses an incremented number as a key.
-- @param Task An item to clean
-- @treturn number TaskId
function Maid:GiveTask(Task: Task): number
	assert(Task, "Task cannot be false or nil")

	local TaskId = (#self._Tasks + 1)
	self[TaskId] = Task

	if type(Task) == "table" and not (Task :: any).Destroy then
		warn("[Maid.GiveTask] - Gave table task without .Destroy\n\n" .. debug.traceback())
	end

	return TaskId
end

function Maid:GivePromise(TaskPromise: Promise): Promise
	if TaskPromise:GetStatus() ~= PromiseModule.Status.Started then
		return TaskPromise
	end

	local NewPromise = PromiseModule.Resolve(TaskPromise)
	local Id = self:GiveTask(NewPromise)

	--// Ensure GC
	NewPromise:Finally(function()
		self[Id] = nil
	end)

	return NewPromise
end

--- Cleans up all tasks.
-- @alias Destroy
function Maid:DoCleaning()
	local Tasks = self._Tasks

	--// Disconnect all events first as we know this is safe
	for Index, Task in pairs(Tasks) do
		if typeof(Task) == "RBXScriptConnection" then
			Tasks[Index] = nil
			Task:Disconnect()
		end
	end

	--// Clear out tasks table completely, even if clean up tasks add more tasks to the maid
	local Index, Task = next(Tasks)
	while Task ~= nil do
		Tasks[Index] = nil

		if type(Task) == "function" then
			Task()
		elseif typeof(Task) == "RBXScriptConnection" then
			Task:Disconnect()
		elseif (Task :: any).Destroy then
			(Task :: any):Destroy()
		end

		Index, Task = next(Tasks)
	end
end

function Maid:Init()
	PromiseModule = self.Shared.Promise
end

--- Alias for DoCleaning()
-- @function Destroy
Maid.Destroy = Maid.DoCleaning

return Maid
