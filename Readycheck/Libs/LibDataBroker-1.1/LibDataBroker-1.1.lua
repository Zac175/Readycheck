--[[
Name: LibDataBroker-1.1
Revision: $Rev: 4 $
Author(s): Tekkub (tekkub@gmail.com)
Website: http://www.wowace.com/projects/libdatabroker-1-1/
Documentation: http://wiki.github.com/tekkub/libdatabroker-1-1
SVN: svn://svn.wowace.com/wow/libdatabroker-1-1/mainline/trunk
Description: A central registry for addons looking for something to display their data
License: Public Domain
]]

local MAJOR, MINOR = "LibDataBroker-1.1", 4
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.callbacks = lib.callbacks or LibStub:GetLibrary("CallbackHandler-1.0"):New(lib)
lib.attributestorage, lib.namestorage, lib.proxystorage = lib.attributestorage or {}, lib.namestorage or {}, lib.proxystorage or {}
local attributestorage, namestorage, proxystorage = lib.attributestorage, lib.namestorage, lib.proxystorage

local domt = {
	__metatable = "access denied",
	__index = function(self, key) return attributestorage[self] and attributestorage[self][key] end,
}

function domt:__newindex(key, value)
	if not attributestorage[self] then attributestorage[self] = {} end
	if attributestorage[self][key] == value then return end
	attributestorage[self][key] = value
	local name = token and namestorage[self]
	if name then
		lib.callbacks:Fire("LibDataBroker_AttributeChanged", name, key, value, self)
		lib.callbacks:Fire("LibDataBroker_AttributeChanged_"..name, name, key, value, self)
		lib.callbacks:Fire("LibDataBroker_AttributeChanged_"..name.."_"..key, name, key, value, self)
		lib.callbacks:Fire("LibDataBroker_AttributeChanged__"..key, name, key, value, self)
	end
end

function lib:NewDataObject(name, dataobj)
	if proxystorage[name] then return end
	
	if dataobj then
		assert(type(dataobj) == "table", "Invalid dataobj, must be nil or a table")
		proxystorage[name] = dataobj
		namestorage[dataobj] = name
		attributestorage[dataobj] = {}
		for i,v in pairs(dataobj) do
			attributestorage[dataobj][i] = v
			dataobj[i] = nil
		end
	else
		dataobj = {}
		proxystorage[name] = dataobj
		namestorage[dataobj] = name
	end
	setmetatable(dataobj, domt)
	lib.callbacks:Fire("LibDataBroker_DataObjectCreated", name, dataobj)
	return dataobj
end

function lib:DataObjectIterator()
	return pairs(proxystorage)
end

function lib:GetDataObjectByName(dataobjectname)
	return proxystorage[dataobjectname]
end

function lib:GetNameByDataObject(dataobject)
	return namestorage[dataobject]
end
