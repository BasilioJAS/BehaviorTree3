--[[
    BEHAVIOR TREE CREATOR V5
	
	Originally by tyridge77: https://devforum.roblox.com/t/btrees-visual-editor-v2-0/461015
	Forked and improved by defaultio

	
	Changes by tyridge77(November 23rd, 2020)
	- Trees are now created only once, and decoupled from objects
	- You now create trees simply by doing BehaviorTreeCreator:Create(treeFolder) - if a tree is already made for that folder it'll return that
	- You now run Trees via Tree:Run(object) 
	- You can now abort a tree via Tree:Abort(object) , used for switching between trees but still calling finish on the previously running task
	- Added support for live debugging
	- Added BehaviorTreeCreator:RegisterBlackboard(name,table)
		- This is used in conjunction with the new blackboard query node
	- Changed up some various internal stuff
--]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local TREE_TAG = "_BTree"

local TreeCreator = {}
local BehaviorTree3 = require(script.BehaviorTree5)

local Trees = {}
local SourceTasks = {}
local TreeIDs = {}
local JsonTreeCache = {}

--------------------------------------------
-------------- PUBLIC METHODS --------------

-- Create tree object from a treeFolder or JSON module.
function TreeCreator:Create(treeFolder, treeId)
	assert(treeFolder, "Invalid parameters, expecting treeFolder, object")

	local Tree = self:_getTree(treeFolder, treeId)
	if Tree then
		return Tree
	else
		warn("Couldn't get tree for ",treeFolder)
	end
end


function TreeCreator:RegisterSharedBlackboard(index,tab)
	assert(index and tab and typeof(index) == "string" and typeof(tab) == "table","RegisterSharedBlackboard takes two arguments in the form of [string] index,[table] table")
	BehaviorTree3.SharedBlackboards[index] = tab
end


---------------------------------------------
-------------- PRIVATE METHODS --------------

local function resolveInstanceFromPath(path)
	if typeof(path) == "Instance" then
		return path
	end
	if typeof(path) ~= "string" or #path == 0 then
		return nil
	end

	local current = game
	for segment in string.gmatch(path, "[^%.]+") do
		if not current then
			break
		end
		current = current:FindFirstChild(segment)
	end
	return current
end


local function normalizeTreeDefinition(treeId, treeDef)
	if not treeDef or typeof(treeDef) ~= "table" then
		return nil
	end

	local nodesContainer = treeDef.Nodes or treeDef.nodes or treeDef
	local nodeLookup = treeDef._nodeLookup
	if not nodeLookup then
		nodeLookup = {}
		if typeof(nodesContainer) == "table" then
			for key, value in pairs(nodesContainer) do
				if typeof(value) == "table" then
					value.Name = value.Name or value.name or key
					if value.Name then
						nodeLookup[value.Name] = value
					end
				end
			end
			if #nodesContainer > 0 then
				for _, value in ipairs(nodesContainer) do
					if typeof(value) == "table" then
						value.Name = value.Name or value.name
						if value.Name then
							nodeLookup[value.Name] = value
						end
					end
				end
			end
		end
		treeDef._nodeLookup = nodeLookup
	end

	for _, node in pairs(nodeLookup) do
		node.Type = node.Type or node.type
		node.Weight = node.Weight or node.weight
		node.Parameters = node.Parameters or node.parameters or {}
		node.Outputs = node.Outputs or node.outputs or {}
		for index, output in ipairs(node.Outputs) do
			if typeof(output) ~= "table" then
				output = {Value = output}
				node.Outputs[index] = output
			end
			output.Name = output.Name or tostring(output.Index or output.index or output.name or 0)
			local value = output.Value or output.value or output.Node
			if typeof(value) == "string" and nodeLookup[value] then
				output.Value = nodeLookup[value]
			elseif value then
				output.Value = value
			end
		end
	end

	treeDef.Nodes = nodeLookup
	treeDef.RootName = treeDef.RootName or treeDef.root or treeDef.Root or "Root"
	treeDef.Name = treeDef.Name or treeDef.name or treeId
	return treeDef
end


local function getTreeDefinitionsFromModule(treeFolder)
	local cached = JsonTreeCache[treeFolder]
	if cached then
		return cached
	end

	local ok, data = pcall(require, treeFolder)
	if not ok then
		warn("Failed to require tree module ", treeFolder, " error: ", data)
		return nil
	end

	if typeof(data) == "string" then
		local success, decoded = pcall(function()
			return HttpService:JSONDecode(data)
		end)
		if success then
			data = decoded
		end
	end

	if typeof(data) ~= "table" then
		warn("Tree module did not return a table or JSON string: ", treeFolder)
		return nil
	end

	JsonTreeCache[treeFolder] = data
	return data
end


local function getJsonTree(treeFolder, treeId)
	local data = typeof(treeFolder) == "Instance" and getTreeDefinitionsFromModule(treeFolder) or treeFolder
	if not data or typeof(data) ~= "table" then
		return nil
	end

	if data.Nodes or data.nodes then
		return normalizeTreeDefinition(treeId, data)
	end

	local trees = data.Trees or data.trees or data
	if treeId and typeof(trees) == "table" then
		if trees[treeId] then
			return normalizeTreeDefinition(treeId, trees[treeId])
		end
		if #trees > 0 then
			for _, treeDef in ipairs(trees) do
				if treeDef and (treeDef.Name == treeId or treeDef.name == treeId) then
					return normalizeTreeDefinition(treeId, treeDef)
				end
			end
		end
	end

	if typeof(trees) == "table" then
		local first
		for key, value in pairs(trees) do
			first = normalizeTreeDefinition(treeId or key, value)
			break
		end
		return first
	end
end


local function GetModule(ModuleScript)
	local found = SourceTasks[ModuleScript]
	if found then
		return found
	else
		found = require(ModuleScript)
		SourceTasks[ModuleScript]=found
		return found
	end
end


local function GetModuleScript(folder, parameters)
	if typeof(folder) ~= "Instance" then
		local moduleRef = parameters and (parameters.module or parameters.source or parameters.Source)
		if not moduleRef and typeof(folder) == "table" then
			moduleRef = folder.Module or folder.module
		end
		return resolveInstanceFromPath(moduleRef)
	end

	local found = folder:FindFirstChildWhichIsA("ModuleScript")
	if found then
		return found
	else
		local link = folder:FindFirstChild("Link")
		if link then
			local linked = link.Value
			if linked then
				return GetModuleScript(linked)
			end
		end
	end
end


-- For task nodes, get module script from node folder
function TreeCreator:_getSourceTask(folder, parameters)
	local ModuleScript = GetModuleScript(folder, parameters)
	if ModuleScript then
		return GetModule(ModuleScript)
	end
end
function TreeCreator:_getExternalSourceTask(folder, parameters)
	local sourceReference = parameters and parameters.source

	if typeof(folder) == "Instance" then
		local SourcePeram = folder.Parameters:FindFirstChild("Source")
		if SourcePeram then
			sourceReference = SourcePeram.Value
		end
	end

	local moduleScript = resolveInstanceFromPath(sourceReference)
	if moduleScript then
		return GetModule(moduleScript)
	end
end


function TreeCreator:_buildNode(folder, nodeLookup)
	local isInstance = typeof(folder) == "Instance"
	local nodeType = isInstance and folder.Type.Value or folder.Type or folder.type
	local weight = isInstance and (folder:FindFirstChild("Weight") and folder.Weight.Value or 1) or folder.Weight or folder.weight or 1
	assert(nodeType, "could't build tree; node missing type")

	local orderedChildren = {}
	if isInstance then
		local Outputs = folder.Outputs:GetChildren()
		for i = 1,#Outputs do
			local objvalue = Outputs[i]
			table.insert(orderedChildren,objvalue)
		end
		table.sort(orderedChildren,function(a,b)
			return tonumber(a.Name) < tonumber(b.Name)
		end)
	else
		local Outputs = folder.Outputs or folder.outputs or {}
		for _, output in pairs(Outputs) do
			table.insert(orderedChildren,output)
		end
		table.sort(orderedChildren,function(a,b)
			local aIndex = tonumber(a.Name or a.Index or a.index or 0) or 0
			local bIndex = tonumber(b.Name or b.Index or b.index or 0) or 0
			return aIndex < bIndex
		end)
	end

	for i = 1,#orderedChildren do
		local childFolder
		if typeof(orderedChildren[i]) == "Instance" then
			childFolder = orderedChildren[i].Value
		else
			childFolder = orderedChildren[i].Value or orderedChildren[i].value
			if typeof(childFolder) == "string" and nodeLookup then
				childFolder = nodeLookup[childFolder]
			end
		end
		assert(childFolder, "could't build tree; child node missing")
		orderedChildren[i] = self:_buildNode(childFolder, nodeLookup)
	end

	local parameters = {}
	if isInstance then
		for _, value in pairs(folder.Parameters:GetChildren()) do
			if not (value.Name == "Index") then
				parameters[string.lower(value.Name)] = value.Value
			end
		end
	else
		local rawParams = folder.Parameters or folder.parameters or {}
		for key, value in pairs(rawParams) do
			if typeof(key) == "string" and string.lower(key) ~= "index" then
				parameters[string.lower(key)] = value
			end
		end
	end

	parameters.nodes = orderedChildren
	parameters.nodefolder = folder

	if nodeType == "Task" then
		local sourcetask = self:_getSourceTask(folder, parameters)
		assert(sourcetask, "could't build tree; task node had no module")
		parameters.start = sourcetask.start
		parameters.run = sourcetask.run
		parameters.finish = sourcetask.finish
	elseif nodeType == "External Task" then
		local sourcetask = self:_getExternalSourceTask(folder, parameters)
		assert(sourcetask, "could't build tree; external task node had no source")
		parameters.start = sourcetask.start
		parameters.run = sourcetask.run
		parameters.finish = sourcetask.finish
	elseif nodeType == "Tree" then
		local tree = self:_getTreeFromId(parameters.treeid)
		assert(tree, string.format("could't build tree; couldn't get tree object for tree node with TreeID:  %s!",tostring(parameters.treeid)))
		parameters.tree = tree
	end

	local node = BehaviorTree3[nodeType](parameters)
	node.weight=weight

	return node
end


function TreeCreator:_createTree(treeFolder, treeId)
	print("Attempt create tree: ",treeFolder, treeId)

	if typeof(treeFolder) == "Instance" and not treeFolder:IsA("ModuleScript") then
		local nodes = treeFolder.Nodes
		local RootFolder = nodes:FindFirstChild("Root")
		assert(RootFolder, string.format("Could not find Root under BehaviorTrees.Trees.%s.Nodes!",treeFolder.Name))
		assert(#RootFolder.Outputs:GetChildren() == 1, string.format("The root node does not have exactly one connection for %s!",treeFolder.Name))

		local firstNodeFolder = RootFolder.Outputs:GetChildren()[1].Value
		local root = self:_buildNode(firstNodeFolder)
		local Tree = BehaviorTree3:new({tree=root,treeFolder = treeFolder})
		Trees[treeFolder] = Tree
		TreeIDs[treeFolder.Name] = Tree
		return Tree	
	end

	local treeDefinition = getJsonTree(treeFolder, treeId or (typeof(treeFolder) == "Instance" and treeFolder.Name))
	assert(treeDefinition, string.format("Could not find tree data for %s", tostring(treeId or (treeFolder and treeFolder.Name) or "tree")))

	local nodes = treeDefinition.Nodes or {}
	local rootName = treeDefinition.RootName or "Root"
	local RootFolder = nodes[rootName] or nodes.Root or nodes[rootName:lower()]
	assert(RootFolder, string.format("Could not find Root node for %s", tostring(treeDefinition.Name)))
	local rawOutputs = RootFolder.Outputs or RootFolder.outputs or {}
	local outputs = {}
	for _, output in pairs(rawOutputs) do
		table.insert(outputs, output)
	end
	table.sort(outputs,function(a,b)
		local aIndex = tonumber(a.Name or a.Index or a.index or 0) or 0
		local bIndex = tonumber(b.Name or b.Index or b.index or 0) or 0
		return aIndex < bIndex
	end)
	assert(#outputs == 1, string.format("The root node does not have exactly one connection for %s!", tostring(treeDefinition.Name)))

	local firstOutput = outputs[1]
	local firstNodeFolder = firstOutput.Value or firstOutput.value
	if typeof(firstNodeFolder) == "string" and treeDefinition._nodeLookup then
		firstNodeFolder = treeDefinition._nodeLookup[firstNodeFolder]
	end

	local root = self:_buildNode(firstNodeFolder, treeDefinition._nodeLookup)
	local Tree = BehaviorTree3:new({tree=root,treeFolder = treeFolder})

	local resolvedName = treeDefinition.Name or treeId or (typeof(treeFolder) == "Instance" and treeFolder.Name) or "Tree"
	treeDefinition.Name = treeDefinition.Name or resolvedName
	if typeof(treeFolder) == "Instance" then
		Trees[treeFolder] = Trees[treeFolder] or {}
		Trees[treeFolder][resolvedName] = Tree
	else
		Trees[treeDefinition] = Tree
	end
	TreeIDs[resolvedName] = Tree
	return Tree
end


function TreeCreator:_getTree(treeFolder, treeId)
	local existing = Trees[treeFolder]
	if typeof(existing) == "table" then
		if treeId and existing[treeId] then
			return existing[treeId]
		end
	elseif existing and not treeId then
		return existing
	end
	return self:_createTree(treeFolder, treeId)
end
-- For tree ndoes to get a tree from
function TreeCreator:_getTreeFromId(treeId)
	local tree = TreeIDs[treeId]
	if not tree then
		for i,folder in pairs(CollectionService:GetTagged(TREE_TAG)) do
			if folder.Name == treeId then
				return self:_getTree(folder, treeId)
			elseif folder:IsA("ModuleScript") then
				if getJsonTree(folder, treeId) then
					return self:_getTree(folder, treeId)
				end
			end
		end
	else
		return tree
	end
end


return TreeCreator
