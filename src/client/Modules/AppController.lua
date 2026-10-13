--!nonstrict

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Theme = require(script.Parent:WaitForChild("Theme"))
local ConsoleCatalog = require(script.Parent:WaitForChild("ConsoleCatalog"))
local CoreRegistry = require(script.Parent:WaitForChild("CoreRegistry"))
local AvalonPreview = require(script.Parent:WaitForChild("AvalonPreview"))

if CoreRegistry.Get("gba") == nil then
	local hostModule = script.Parent:FindFirstChild("GBAHost")
	local loaded, core = false, nil
	if hostModule and hostModule:IsA("ModuleScript") then
		loaded, core = pcall(require, hostModule)
	end
	if loaded and core then
		local registered, reason = CoreRegistry.Register("gba", core)
		if not registered then
			warn("Short Stack could not register the Depth GBA core: " .. reason)
		end
	else
		warn("Short Stack could not load the local Depth GBA adapter; the library UI will remain available.")
	end
end

local Controller = {}
Controller.__index = Controller

local function make(className, properties, parent)
	local object = Instance.new(className)
	for property, value in pairs(properties or {}) do
		object[property] = value
	end
	object.Parent = parent
	return object
end

local function addCorner(parent, radius)
	return make("UICorner", {
		CornerRadius = UDim.new(0, radius or 12),
	}, parent)
end

local function addStroke(parent, color, transparency, thickness)
	return make("UIStroke", {
		Color = color or Theme.Colors.Border,
		Transparency = transparency or 0,
		Thickness = thickness or 1,
	}, parent)
end

local function addLabel(parent, text, position, size, options)
	options = options or {}
	local defaultZIndex = 1
	if parent:IsA("GuiObject") then
		defaultZIndex = parent.ZIndex + 1
	end
	return make("TextLabel", {
		Name = options.Name or "Label",
		Position = position,
		Size = size,
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = options.Color or Theme.Colors.Text,
		TextSize = options.TextSize or 14,
		Font = options.Font or Theme.Fonts.Regular,
		TextXAlignment = options.XAlignment or Enum.TextXAlignment.Left,
		TextYAlignment = options.YAlignment or Enum.TextYAlignment.Center,
		TextWrapped = options.Wrapped or false,
		TextTruncate = options.Truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		RichText = false,
		ZIndex = options.ZIndex or defaultZIndex,
	}, parent)
end

local function addPill(parent, text, position, size, color, background, zIndex)
	local pill = make("Frame", {
		Position = position,
		Size = size,
		BackgroundColor3 = background or Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		ZIndex = zIndex or 1,
	}, parent)
	addCorner(pill, 20)
	addLabel(pill, text, UDim2.fromOffset(10, 0), UDim2.new(1, -20, 1, 0), {
		Color = color or Theme.Colors.Muted,
		TextSize = 10,
		Font = Theme.Fonts.Mono,
		XAlignment = Enum.TextXAlignment.Center,
		ZIndex = (zIndex or 1) + 1,
	})
	return pill
end

function Controller.new()
	return setmetatable({
		_started = false,
		_connections = {},
		_dynamicConnections = {},
		_modalConnections = {},
		_playerConnections = {},
		_playerHost = nil,
		_playerOverlay = nil,
		_activeFilter = "All",
		_searchText = "",
		_modal = nil,
	}, Controller)
end

function Controller:_connect(signal, callback, bucketName)
	local connection = signal:Connect(callback)
	local bucket = self._connections
	if bucketName == "dynamic" then
		bucket = self._dynamicConnections
	elseif bucketName == "modal" then
		bucket = self._modalConnections
	elseif bucketName == "player" then
		bucket = self._playerConnections
	end
	table.insert(bucket, connection)
	return connection
end

function Controller:_disconnectBucket(bucket)
	for _, connection in ipairs(bucket) do
		connection:Disconnect()
	end
	table.clear(bucket)
end

function Controller:Start()
	if self._started then
		return
	end
	self._started = true

	local player = Players.LocalPlayer
	if not player then
		warn("Short Stack must start from a LocalScript.")
		return
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local previous = playerGui:FindFirstChild("ShortStackUI")
	if previous then
		previous:Destroy()
	end

	self._screen = make("ScreenGui", {
		Name = "ShortStackUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 20,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)

	self._root = make("Frame", {
		Name = "Background",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, self._screen)
	make("UIGradient", {
		Rotation = 110,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(13, 20, 27)),
			ColorSequenceKeypoint.new(1, Theme.Colors.Background),
		}),
	}, self._root)

	self:_buildSidebar()
	self:_buildContent()
	self:_connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		self:_watchCamera()
		self:_applyResponsiveLayout()
	end)
	self:_watchCamera()
	self:_applyResponsiveLayout()
	self:_renderGrid()
end

function Controller:_buildSidebar()
	local sidebar = make("Frame", {
		Name = "Sidebar",
		Position = UDim2.fromOffset(22, 22),
		Size = UDim2.new(0, 218, 1, -44),
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, self._root)
	addCorner(sidebar, 18)
	addStroke(sidebar, Theme.Colors.BorderSoft, 0, 1)
	self._sidebar = sidebar

	local mark = make("Frame", {
		Position = UDim2.fromOffset(18, 20),
		Size = UDim2.fromOffset(42, 42),
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, sidebar)
	addCorner(mark, 13)
	addLabel(mark, "S", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), {
		Color = Theme.Colors.Background,
		TextSize = 23,
		Font = Theme.Fonts.Bold,
		XAlignment = Enum.TextXAlignment.Center,
		ZIndex = 4,
	})
	addLabel(sidebar, "SHORT//STACK", UDim2.fromOffset(70, 20), UDim2.new(1, -84, 0, 22), {
		TextSize = 14,
		Font = Theme.Fonts.Bold,
	})
	addLabel(sidebar, "LOCAL ARCADE", UDim2.fromOffset(71, 42), UDim2.new(1, -84, 0, 17), {
		Color = Theme.Colors.Muted,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
	})

	make("Frame", {
		Position = UDim2.new(0, 16, 0, 82),
		Size = UDim2.new(1, -32, 0, 1),
		BackgroundColor3 = Theme.Colors.BorderSoft,
		BorderSizePixel = 0,
	}, sidebar)

	addLabel(sidebar, "WORKSPACE", UDim2.fromOffset(20, 101), UDim2.new(1, -40, 0, 18), {
		Color = Theme.Colors.Dim,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
	})

	local libraryButton = make("TextButton", {
		Name = "LibraryButton",
		Position = UDim2.fromOffset(12, 128),
		Size = UDim2.new(1, -24, 0, 42),
		BackgroundColor3 = Theme.Colors.AccentDeep,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 3,
	}, sidebar)
	addCorner(libraryButton, 11)
	make("Frame", {
		Position = UDim2.fromOffset(11, 13),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, libraryButton)
	addLabel(libraryButton, "SYSTEM LIBRARY", UDim2.fromOffset(39, 0), UDim2.new(1, -48, 1, 0), {
		Color = Theme.Colors.Accent,
		TextSize = 11,
		Font = Theme.Fonts.Bold,
		ZIndex = 4,
	})

	addLabel(sidebar, "SYSTEM STATUS", UDim2.fromOffset(20, 194), UDim2.new(1, -40, 0, 18), {
		Color = Theme.Colors.Dim,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
	})

	local statusPanel = make("Frame", {
		Position = UDim2.fromOffset(12, 220),
		Size = UDim2.new(1, -24, 0, 106),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
	}, sidebar)
	addCorner(statusPanel, 12)
	addStroke(statusPanel, Theme.Colors.BorderSoft, 0, 1)
	addLabel(statusPanel, "CONNECTED CORES", UDim2.fromOffset(13, 12), UDim2.new(1, -26, 0, 16), {
		Color = Theme.Colors.Muted,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
	})
	self._sidebarCoreCount = addLabel(statusPanel, "0 / 8", UDim2.fromOffset(13, 31), UDim2.new(1, -26, 0, 30), {
		Color = Theme.Colors.Text,
		TextSize = 21,
		Font = Theme.Fonts.Bold,
	})
	addLabel(statusPanel, "No cores linked in this checkout", UDim2.fromOffset(13, 68), UDim2.new(1, -26, 0, 24), {
		Color = Theme.Colors.Muted,
		TextSize = 10,
		Wrapped = true,
	})

	local footer = make("Frame", {
		Name = "ClientOnlyFooter",
		Position = UDim2.new(0, 12, 1, -66),
		Size = UDim2.new(1, -24, 0, 50),
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
	}, sidebar)
	addCorner(footer, 12)
	local dot = make("Frame", {
		Position = UDim2.fromOffset(13, 18),
		Size = UDim2.fromOffset(7, 7),
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
	}, footer)
	addCorner(dot, 4)
	addLabel(footer, "CLIENT-ONLY SHELL", UDim2.fromOffset(29, 7), UDim2.new(1, -38, 0, 18), {
		Color = Theme.Colors.Text,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
	})
	addLabel(footer, "No server runtime", UDim2.fromOffset(29, 24), UDim2.new(1, -38, 0, 16), {
		Color = Theme.Colors.Muted,
		TextSize = 9,
	})
end

function Controller:_buildContent()
	local main = make("Frame", {
		Name = "MainContent",
		Position = UDim2.fromOffset(264, 22),
		Size = UDim2.new(1, -286, 1, -44),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, self._root)
	self._main = main

	local eyebrow = addLabel(main, "SHORT STACK   /   MULTI-SYSTEM LIBRARY", UDim2.fromOffset(2, 0), UDim2.new(1, -210, 0, 42), {
		Color = Theme.Colors.Muted,
		TextSize = 10,
		Font = Theme.Fonts.Mono,
	})
	self._headerLabel = eyebrow

	local coreBadge = make("Frame", {
		Name = "CoreBadge",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 6),
		Size = UDim2.fromOffset(168, 30),
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
	}, main)
	addCorner(coreBadge, 15)
	addStroke(coreBadge, Theme.Colors.BorderSoft, 0, 1)
	local headerDot = make("Frame", {
		Position = UDim2.fromOffset(12, 11),
		Size = UDim2.fromOffset(7, 7),
		BackgroundColor3 = Theme.Colors.Amber,
		BorderSizePixel = 0,
	}, coreBadge)
	addCorner(headerDot, 4)
	self._headerCoreText = addLabel(coreBadge, "0 / 8 CORES", UDim2.fromOffset(27, 0), UDim2.new(1, -34, 1, 0), {
		Color = Theme.Colors.Muted,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
	})
	self._headerCoreDot = headerDot

	self:_buildHero(main)
	self:_buildToolbar(main)

	self._sectionTitle = addLabel(main, "SYSTEM CATALOG", UDim2.fromOffset(2, 329), UDim2.new(1, -120, 0, 25), {
		Color = Theme.Colors.Text,
		TextSize = 12,
		Font = Theme.Fonts.Bold,
	})
	self._sectionCount = addLabel(main, "08 PLATFORMS", UDim2.new(1, -124, 0, 329), UDim2.fromOffset(122, 25), {
		Color = Theme.Colors.Dim,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		XAlignment = Enum.TextXAlignment.Right,
	})

	local scroll = make("ScrollingFrame", {
		Name = "ConsoleGridScroll",
		Position = UDim2.fromOffset(0, 362),
		Size = UDim2.new(1, 0, 1, -362),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Colors.Accent,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.fromOffset(0, 0),
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		ZIndex = 2,
	}, main)
	self._scroll = scroll

	local grid = make("Frame", {
		Name = "ConsoleGrid",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, scroll)
	self._grid = grid
	local gridLayout = make("UIGridLayout", {
		CellSize = UDim2.fromOffset(240, 154),
		CellPadding = UDim2.fromOffset(12, 12),
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	self._gridLayout = gridLayout

	self._emptyState = addLabel(scroll, "No systems match that search. Try another name or filter.", UDim2.fromOffset(12, 28), UDim2.new(1, -24, 0, 48), {
		Color = Theme.Colors.Muted,
		TextSize = 13,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
	})
	self._emptyState.Visible = false

	self:_connect(gridLayout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
		local height = gridLayout.AbsoluteContentSize.Y
		scroll.CanvasSize = UDim2.fromOffset(0, math.max(height + 6, self._emptyState.Visible and 90 or 0))
	end)
	self:_connect(gridLayout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
		self:_updateGridColumns()
	end)
	self:_connect(scroll:GetPropertyChangedSignal("AbsoluteSize"), function()
		self:_updateGridColumns()
	end)
	self:_connect(grid:GetPropertyChangedSignal("AbsoluteSize"), function()
		self:_updateGridColumns()
	end)
end

function Controller:_buildHero(parent)
	local hero = make("Frame", {
		Name = "HeroPanel",
		Position = UDim2.fromOffset(0, 54),
		Size = UDim2.new(1, 0, 0, 196),
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, parent)
	addCorner(hero, 18)
	addStroke(hero, Theme.Colors.Border, 0, 1)
	make("UIGradient", {
		Rotation = 0,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(19, 33, 37)),
			ColorSequenceKeypoint.new(0.56, Theme.Colors.Panel),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(25, 26, 42)),
		}),
	}, hero)

	addLabel(hero, "LOCAL-FIRST  /  NO SERVERS", UDim2.fromOffset(24, 17), UDim2.new(0.62, -24, 0, 18), {
		Color = Theme.Colors.Accent,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
	})
	self._heroTitle = addLabel(hero, "Every era.\nOne stack.", UDim2.fromOffset(22, 41), UDim2.new(0.61, -22, 0, 84), {
		Color = Theme.Colors.Text,
		TextSize = 34,
		Font = Theme.Fonts.Bold,
		Wrapped = true,
		YAlignment = Enum.TextYAlignment.Top,
	})
	self._heroSubtitle = addLabel(hero, "A focused front end for the classics — built to stay light, local, and ready for audited cores.", UDim2.fromOffset(24, 130), UDim2.new(0.60, -24, 0, 42), {
		Color = Theme.Colors.Muted,
		TextSize = 12,
		Wrapped = true,
		YAlignment = Enum.TextYAlignment.Top,
	})

	local device = make("Frame", {
		Name = "ArcadeDeviceArt",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -28, 0.5, 1),
		Size = UDim2.fromOffset(230, 145),
		BackgroundColor3 = Color3.fromRGB(30, 39, 48),
		BorderSizePixel = 0,
		Rotation = -3,
		ZIndex = 2,
	}, hero)
	addCorner(device, 18)
	addStroke(device, Color3.fromRGB(73, 91, 101), 0.1, 1)

	local screen = make("Frame", {
		Position = UDim2.fromOffset(18, 15),
		Size = UDim2.new(1, -36, 0, 78),
		BackgroundColor3 = Color3.fromRGB(9, 16, 20),
		BorderSizePixel = 0,
		ZIndex = 3,
	}, device)
	addCorner(screen, 10)
	addStroke(screen, Theme.Colors.AccentDeep, 0.15, 1)
	addLabel(screen, "SHORT//STACK", UDim2.fromOffset(0, 16), UDim2.new(1, 0, 0, 18), {
		Color = Theme.Colors.Accent,
		TextSize = 12,
		Font = Theme.Fonts.Mono,
		XAlignment = Enum.TextXAlignment.Center,
		ZIndex = 4,
	})
	addLabel(screen, "DEPTH CORE  ·  TEST PENDING", UDim2.fromOffset(0, 39), UDim2.new(1, 0, 0, 16), {
		Color = Theme.Colors.Amber,
		TextSize = 8,
		Font = Theme.Fonts.Mono,
		XAlignment = Enum.TextXAlignment.Center,
		ZIndex = 4,
	})
	self._deviceScreen = screen

	local controls = make("Frame", {
		Position = UDim2.fromOffset(20, 105),
		Size = UDim2.fromOffset(51, 25),
		BackgroundTransparency = 1,
		ZIndex = 3,
	}, device)
	for _, control in ipairs({
		{ x = 17, y = 0 },
		{ x = 17, y = 16 },
		{ x = 0, y = 8 },
		{ x = 34, y = 8 },
	}) do
		make("Frame", {
			Position = UDim2.fromOffset(control.x, control.y),
			Size = UDim2.fromOffset(control.x == 17 and 17 or 17, 9),
			BackgroundColor3 = Color3.fromRGB(91, 106, 115),
			BorderSizePixel = 0,
			ZIndex = 4,
		}, controls)
	end
	for index, color in ipairs({ Theme.Colors.Red, Theme.Colors.Accent }) do
		local button = make("Frame", {
			Position = UDim2.fromOffset(166 + (index - 1) * 23, 109),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 4,
		}, device)
		addCorner(button, 8)
	end

	local lowerTrim = make("Frame", {
		Position = UDim2.new(0, 85, 1, -12),
		Size = UDim2.new(1, -170, 0, 3),
		BackgroundColor3 = Color3.fromRGB(65, 77, 87),
		BorderSizePixel = 0,
		ZIndex = 3,
	}, device)
	addCorner(lowerTrim, 2)
	self._device = device
	self._hero = hero
end

function Controller:_buildToolbar(parent)
	local toolbar = make("Frame", {
		Name = "LibraryToolbar",
		Position = UDim2.fromOffset(0, 263),
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundTransparency = 1,
	}, parent)
	self._toolbar = toolbar

	local search = make("Frame", {
		Name = "SearchBox",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(262, 42),
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
	}, toolbar)
	self._searchContainer = search
	addCorner(search, 11)
	addStroke(search, Theme.Colors.BorderSoft, 0, 1)
	addLabel(search, "⌕", UDim2.fromOffset(13, 0), UDim2.fromOffset(22, 42), {
		Color = Theme.Colors.Muted,
		TextSize = 21,
		Font = Theme.Fonts.Regular,
		XAlignment = Enum.TextXAlignment.Center,
	})
	local input = make("TextBox", {
		Name = "SearchInput",
		Position = UDim2.fromOffset(42, 0),
		Size = UDim2.new(1, -53, 1, 0),
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = "Find a system...",
		PlaceholderColor3 = Theme.Colors.Dim,
		TextColor3 = Theme.Colors.Text,
		TextSize = 12,
		Font = Theme.Fonts.Regular,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
	}, search)
	self._searchInput = input
	self:_connect(input:GetPropertyChangedSignal("Text"), function()
		self._searchText = string.lower(input.Text)
		self:_renderGrid()
	end)

	local filters = make("Frame", {
		Name = "SystemFilters",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(332, 42),
		BackgroundTransparency = 1,
	}, toolbar)
	self._filterFrame = filters
	self._filterButtons = {}

	for _, item in ipairs({
		{ id = "All", text = "All systems", width = 104 },
		{ id = "Handheld", text = "Handheld", width = 104 },
		{ id = "Home", text = "Home systems", width = 112 },
	}) do
		local button = make("TextButton", {
			Name = item.id .. "Filter",
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.fromOffset(item.width, 40),
			BackgroundColor3 = Theme.Colors.Panel,
			BorderSizePixel = 0,
			Text = item.text,
			TextColor3 = Theme.Colors.Muted,
			TextSize = 10,
			Font = Theme.Fonts.Medium,
			AutoButtonColor = false,
			ZIndex = 3,
		}, filters)
		addCorner(button, 10)
		addStroke(button, Theme.Colors.BorderSoft, 0, 1)
		self._filterButtons[item.id] = button
		self:_connect(button.Activated, function()
			self:_setFilter(item.id)
		end)
	end

	self._filterDefinitions = {
		{ id = "All", width = 104 },
		{ id = "Handheld", width = 104 },
		{ id = "Home", width = 112 },
	}
end

function Controller:_watchCamera()
	if self._cameraConnection then
		self._cameraConnection:Disconnect()
		self._cameraConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		self._cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			self:_applyResponsiveLayout()
		end)
	end
end

function Controller:_applyResponsiveLayout()
	if not self._main or not self._sidebar then
		return
	end

	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local compact = viewport.X < 1100
	local mobile = viewport.X < 720

	self._sidebar.Visible = not compact
	if compact then
		self._main.Position = UDim2.fromOffset(16, 16)
		self._main.Size = UDim2.new(1, -32, 1, -32)
	else
		self._main.Position = UDim2.fromOffset(264, 22)
		self._main.Size = UDim2.new(1, -286, 1, -44)
	end

	if mobile then
		self._heroTitle.TextSize = 28
		self._heroTitle.Size = UDim2.new(1, -38, 0, 74)
		self._heroSubtitle.Size = UDim2.new(1, -48, 0, 44)
		self._heroSubtitle.Position = UDim2.fromOffset(24, 119)
		self._device.Visible = false
		self._searchContainer.Size = UDim2.new(1, 0, 0, 40)
		self._searchContainer.Position = UDim2.fromOffset(0, 0)
		self._filterFrame.AnchorPoint = Vector2.new(0, 0)
		self._filterFrame.Position = UDim2.fromOffset(0, 46)
		self._filterFrame.Size = UDim2.new(1, 0, 0, 38)
		self._toolbar.Size = UDim2.new(1, 0, 0, 86)
		self._toolbar.Position = UDim2.fromOffset(0, 263)
		local filterWidth = math.max(0, viewport.X - 32)
		local filterButtonWidth = math.max(64, math.floor((filterWidth - 16) / 3))
		for index, definition in ipairs(self._filterDefinitions) do
			local button = self._filterButtons[definition.id]
			button.Position = UDim2.fromOffset((index - 1) * (filterButtonWidth + 8), 0)
			button.Size = UDim2.fromOffset(filterButtonWidth, 36)
		end
		local sectionY = 263 + 86 + 10
		self._sectionTitle.Position = UDim2.fromOffset(2, sectionY)
		self._sectionCount.Position = UDim2.new(1, -124, 0, sectionY)
		self._scroll.Position = UDim2.fromOffset(0, sectionY + 32)
		self._scroll.Size = UDim2.new(1, 0, 1, -(sectionY + 32))
	else
		self._heroTitle.TextSize = 34
		self._heroTitle.Size = UDim2.new(0.61, -22, 0, 84)
		self._heroSubtitle.Size = UDim2.new(0.60, -24, 0, 42)
		self._heroSubtitle.Position = UDim2.fromOffset(24, 130)
		self._device.Visible = true
		self._searchContainer.Size = UDim2.fromOffset(262, 42)
		self._searchContainer.Position = UDim2.fromOffset(0, 0)
		self._filterFrame.AnchorPoint = Vector2.new(1, 0)
		self._filterFrame.Position = UDim2.new(1, 0, 0, 0)
		self._filterFrame.Size = UDim2.fromOffset(332, 42)
		self._toolbar.Size = UDim2.new(1, 0, 0, 46)
		self._toolbar.Position = UDim2.fromOffset(0, 263)
		local x = 0
		for _, definition in ipairs(self._filterDefinitions) do
			local button = self._filterButtons[definition.id]
			button.Position = UDim2.fromOffset(x, 0)
			button.Size = UDim2.fromOffset(definition.width, 40)
			x += definition.width + 6
		end
		local sectionY = 329
		self._sectionTitle.Position = UDim2.fromOffset(2, sectionY)
		self._sectionCount.Position = UDim2.new(1, -124, 0, sectionY)
		self._scroll.Position = UDim2.fromOffset(0, 362)
		self._scroll.Size = UDim2.new(1, 0, 1, -362)
	end

	if not mobile and not self._avalonPreviewAttempted and self._deviceScreen then
		self._avalonPreviewAttempted = true
		self._avalonPreview = AvalonPreview.Render(self._deviceScreen, Theme.Colors.Accent)
	end
	self:_updateGridColumns()
end

function Controller:_updateGridColumns()
	if not self._gridLayout or not self._grid then
		return
	end
	local width = self._grid.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local columns
	if width >= 2100 then
		columns = 8
	elseif width >= 1800 then
		columns = 7
	elseif width >= 1500 then
		columns = 6
	elseif width >= 1200 then
		columns = 5
	elseif width >= 1000 then
		columns = 4
	elseif width >= 650 then
		columns = 3
	elseif width >= 430 then
		columns = 2
	else
		columns = 1
	end
	local gap = 12
	local cellWidth = math.max(1, math.floor((width - gap * (columns - 1)) / columns))
	self._gridLayout.CellSize = UDim2.fromOffset(cellWidth, 154)
	self._gridLayout.CellPadding = UDim2.fromOffset(gap, gap)
end

function Controller:_setFilter(filterId)
	self._activeFilter = filterId
	for id, button in pairs(self._filterButtons) do
		local selected = id == filterId
		button.BackgroundColor3 = selected and Theme.Colors.AccentDeep or Theme.Colors.Panel
		button.TextColor3 = selected and Theme.Colors.Accent or Theme.Colors.Muted
	end
	self:_renderGrid()
end

function Controller:_renderGrid()
	if not self._grid then
		return
	end
	self:_disconnectBucket(self._dynamicConnections)
	for _, child in ipairs(self._grid:GetChildren()) do
		if not child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end

	local visible = {}
	for _, console in ipairs(ConsoleCatalog.GetAll()) do
		local familyMatches = self._activeFilter == "All" or console.family == self._activeFilter
		local searchMatches = self._searchText == ""
		if not searchMatches then
			local query = self._searchText
			local searchable = string.lower(table.concat({
				console.name,
				console.shortName,
				console.manufacturer,
				console.family,
				console.format,
			}, " "))
			searchMatches = string.find(searchable, query, 1, true) ~= nil
		end
		if familyMatches and searchMatches then
			table.insert(visible, console)
		end
	end

	for index, console in ipairs(visible) do
		self:_createConsoleCard(console, index)
	end
	self._emptyState.Visible = #visible == 0
	self._sectionCount.Text = string.format("%02d SYSTEM%s", #visible, #visible == 1 and "" or "S")
	local height = self._gridLayout.AbsoluteContentSize.Y
	self._scroll.CanvasSize = UDim2.fromOffset(0, math.max(height + 6, #visible == 0 and 90 or 0))
	self:_updateCoreCounts()
	self:_updateGridColumns()
end

function Controller:_createConsoleCard(console, order)
	local status = CoreRegistry.GetStatus(console.id)
	local card = make("TextButton", {
		Name = "Console_" .. console.id,
		LayoutOrder = order,
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ClipsDescendants = true,
		ZIndex = 2,
	}, self._grid)
	addCorner(card, 14)
	local outline = addStroke(card, Theme.Colors.BorderSoft, 0, 1)

	local icon = make("Frame", {
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.fromOffset(45, 42),
		BackgroundColor3 = console.accent,
		BackgroundTransparency = 0.86,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, card)
	addCorner(icon, 10)
	addLabel(icon, console.shortName, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), {
		Color = console.accent,
		TextSize = #console.shortName > 3 and 10 or 12,
		Font = Theme.Fonts.Bold,
		XAlignment = Enum.TextXAlignment.Center,
		ZIndex = 4,
	})
	addLabel(card, console.era, UDim2.new(1, -60, 0, 15), UDim2.fromOffset(46, 15), {
		Color = Theme.Colors.Dim,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		XAlignment = Enum.TextXAlignment.Right,
		ZIndex = 3,
	})
	addLabel(card, console.name, UDim2.fromOffset(14, 66), UDim2.new(1, -28, 0, 23), {
		Color = Theme.Colors.Text,
		TextSize = 14,
		Font = Theme.Fonts.Bold,
		Truncate = true,
		ZIndex = 3,
	})
	addLabel(card, console.format, UDim2.fromOffset(14, 91), UDim2.new(1, -28, 0, 18), {
		Color = Theme.Colors.Muted,
		TextSize = 10,
		Truncate = true,
		ZIndex = 3,
	})

	local chipColor = status.ready and Theme.Colors.Accent or Theme.Colors.Amber
	local chipBackground = status.ready and Theme.Colors.AccentDeep or Color3.fromRGB(54, 42, 28)
	addPill(card, status.label, UDim2.fromOffset(14, 120), UDim2.fromOffset(104, 21), chipColor, chipBackground, 3)
	addLabel(card, console.resolution, UDim2.new(1, -120, 0, 120), UDim2.fromOffset(106, 21), {
		Color = Theme.Colors.Dim,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		XAlignment = Enum.TextXAlignment.Right,
		ZIndex = 3,
	})

	self:_connect(card.Activated, function()
		self:_openDetails(console)
	end, "dynamic")
	self:_connect(card.MouseEnter, function()
		TweenService:Create(card, TweenInfo.new(0.12), {
			BackgroundColor3 = Theme.Colors.PanelHover,
		}):Play()
		outline.Color = console.accent
		outline.Transparency = 0.34
	end, "dynamic")
	self:_connect(card.MouseLeave, function()
		TweenService:Create(card, TweenInfo.new(0.12), {
			BackgroundColor3 = Theme.Colors.Panel,
		}):Play()
		outline.Color = Theme.Colors.BorderSoft
		outline.Transparency = 0
	end, "dynamic")
end

function Controller:_updateCoreCounts()
	local installed = CoreRegistry.Count()
	local total = #ConsoleCatalog.GetAll()
	if self._headerCoreText then
		self._headerCoreText.Text = string.format("%d / %d CORES", installed, total)
	end
	if self._sidebarCoreCount then
		self._sidebarCoreCount.Text = string.format("%d / %d", installed, total)
	end
	if self._headerCoreDot then
		self._headerCoreDot.BackgroundColor3 = installed > 0 and Theme.Colors.Accent or Theme.Colors.Amber
	end
end

function Controller:_openDetails(console)
	self:_closeModal()
	local status = CoreRegistry.GetStatus(console.id)
	local overlay = make("TextButton", {
		Name = "ConsoleDetailsOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(2, 4, 7),
		BackgroundTransparency = 0.28,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 5,
	}, self._screen)
	self._modal = overlay
	self:_connect(overlay.Activated, function()
		self:_closeModal()
	end, "modal")

	local dialog = make("Frame", {
		Name = "DetailsDialog",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -32, 0, 350),
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
		ZIndex = 6,
	}, overlay)
	addCorner(dialog, 18)
	addStroke(dialog, Theme.Colors.Border, 0, 1)
	make("UISizeConstraint", {
		MinSize = Vector2.new(280, 320),
		MaxSize = Vector2.new(520, 350),
	}, dialog)

	local close = make("TextButton", {
		Name = "CloseDetails",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		Text = "×",
		TextColor3 = Theme.Colors.Muted,
		TextSize = 20,
		Font = Theme.Fonts.Regular,
		AutoButtonColor = true,
		ZIndex = 7,
	}, dialog)
	addCorner(close, 10)
	self:_connect(close.Activated, function()
		self:_closeModal()
	end, "modal")

	addLabel(dialog, string.upper(console.manufacturer) .. "   /   " .. console.shortName, UDim2.fromOffset(24, 19), UDim2.new(1, -82, 0, 18), {
		Color = console.accent,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		ZIndex = 7,
	})
	addLabel(dialog, console.name, UDim2.fromOffset(22, 47), UDim2.new(1, -44, 0, 36), {
		Color = Theme.Colors.Text,
		TextSize = 22,
		Font = Theme.Fonts.Bold,
		Truncate = true,
		ZIndex = 7,
	})
	addLabel(dialog, console.format .. "  ·  " .. console.family, UDim2.fromOffset(24, 86), UDim2.new(1, -48, 0, 20), {
		Color = Theme.Colors.Muted,
		TextSize = 11,
		ZIndex = 7,
	})

	local stats = make("Frame", {
		Position = UDim2.fromOffset(24, 121),
		Size = UDim2.new(1, -48, 0, 54),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		ZIndex = 7,
	}, dialog)
	addCorner(stats, 11)
	addLabel(stats, "ERA", UDim2.fromOffset(13, 7), UDim2.new(0.5, -16, 0, 13), {
		Color = Theme.Colors.Dim,
		TextSize = 8,
		Font = Theme.Fonts.Mono,
		ZIndex = 8,
	})
	addLabel(stats, console.era, UDim2.fromOffset(13, 22), UDim2.new(0.5, -16, 0, 21), {
		Color = Theme.Colors.Text,
		TextSize = 12,
		Font = Theme.Fonts.Medium,
		ZIndex = 8,
	})
	addLabel(stats, "FRAMEBUFFER", UDim2.new(0.5, 4, 0, 7), UDim2.new(0.5, -16, 0, 13), {
		Color = Theme.Colors.Dim,
		TextSize = 8,
		Font = Theme.Fonts.Mono,
		ZIndex = 8,
	})
	addLabel(stats, console.resolution, UDim2.new(0.5, 4, 0, 22), UDim2.new(0.5, -16, 0, 21), {
		Color = Theme.Colors.Text,
		TextSize = 12,
		Font = Theme.Fonts.Medium,
		ZIndex = 8,
	})

	local statusPanel = make("Frame", {
		Position = UDim2.fromOffset(24, 189),
		Size = UDim2.new(1, -48, 0, 72),
		BackgroundColor3 = Color3.fromRGB(45, 36, 27),
		BorderSizePixel = 0,
		ZIndex = 7,
	}, dialog)
	addCorner(statusPanel, 11)
	addLabel(statusPanel, status.label, UDim2.fromOffset(13, 9), UDim2.new(1, -26, 0, 16), {
		Color = status.ready and Theme.Colors.Accent or Theme.Colors.Amber,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		ZIndex = 8,
	})
	addLabel(statusPanel, console.coreRequirement .. ". " .. status.detail, UDim2.fromOffset(13, 27), UDim2.new(1, -26, 0, 37), {
		Color = Theme.Colors.Muted,
		TextSize = 10,
		Wrapped = true,
		YAlignment = Enum.TextYAlignment.Top,
		ZIndex = 8,
	})

	local canRunGBA = console.id == "gba" and status.ready
	local note = if canRunGBA
		then "An original homebrew demo launch path is wired, but Studio testing is pending. No commercial ROM or other game data is bundled."
		else "No emulator core is installed for this system yet. This entry is a catalog target, not a playable console."
	addLabel(dialog, note, UDim2.fromOffset(24, 265), UDim2.new(1, -48, 0, 28), {
		Color = Theme.Colors.Dim,
		TextSize = 10,
		Wrapped = true,
		ZIndex = 7,
	})

	local runDemo = make("TextButton", {
		Name = "RunOriginalDemo",
		Position = UDim2.new(0, 24, 1, -52),
		Size = canRunGBA and UDim2.new(0.5, -28, 0, 36) or UDim2.new(1, -48, 0, 36),
		BackgroundColor3 = canRunGBA and Theme.Colors.AccentDeep or Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		Text = canRunGBA and "TRY ORIGINAL DEMO" or "CONSOLE CORE NOT LINKED",
		TextColor3 = canRunGBA and Theme.Colors.Accent or Theme.Colors.Dim,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		AutoButtonColor = canRunGBA,
		Active = canRunGBA,
		ZIndex = 7,
	}, dialog)
	addCorner(runDemo, 10)

	if canRunGBA then
		local loadRom = make("TextButton", {
			Name = "LoadLocalROM",
			Position = UDim2.new(0.5, 4, 1, -52),
			Size = UDim2.new(0.5, -28, 0, 36),
			BackgroundColor3 = Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
			Text = "LOAD EMBEDDED ROM",
			TextColor3 = Theme.Colors.Text,
			TextSize = 9,
			Font = Theme.Fonts.Mono,
			AutoButtonColor = true,
			Active = true,
			ZIndex = 7,
		}, dialog)
		addCorner(loadRom, 10)
		self:_connect(runDemo.Activated, function()
			self:_closeModal()
			self:_launchGBA("demo")
		end, "modal")
		self:_connect(loadRom.Activated, function()
			self:_closeModal()
			self:_launchGBA("installed")
		end, "modal")
	end
end

function Controller:_layoutPlayer()
	if not self._playerOverlay or not self._playerViewport then
		return
	end

	local size = self._playerOverlay.AbsoluteSize
	local width = math.max(size.X, 280)
	local height = math.max(size.Y, 260)
	local touchEnabled = UserInputService.TouchEnabled
	local top = 72
	local bottomReserve = touchEnabled and 166 or 62
	local availableWidth = math.max(1, width - 32)
	local availableHeight = math.max(80, height - top - bottomReserve)
	local gameWidth = math.min(availableWidth, availableHeight * 1.5, 920)
	local gameHeight = gameWidth / 1.5
	local gameY = top + math.max(0, (availableHeight - gameHeight) / 2)

	self._playerViewport.Position = UDim2.fromOffset((width - gameWidth) / 2, gameY)
	self._playerViewport.Size = UDim2.fromOffset(gameWidth, gameHeight)
	self._playerInfo.Position = UDim2.fromOffset(16, gameY + 10)
	self._playerInfo.Size = UDim2.new(1, -32, 1, -20)
	self._playerMetrics.Visible = not touchEnabled
	self._playerMetrics.Size = UDim2.new(1, touchEnabled and -32 or -196, 0, 20)
	self._playerMetrics.Position = UDim2.new(0, 16, 1, -42)
	self._playerSaveButton.Visible = not touchEnabled
	self._playerLoadButton.Visible = not touchEnabled
	if self._playerControls then
		self._playerControls.Visible = touchEnabled and self._playerHost ~= nil
			and self._playerHost:IsRunning()
		if touchEnabled then
			local desiredY = gameY + gameHeight + 10
			local controlsY = math.max(desiredY, height - 170)
			if controlsY + 148 > height then
				controlsY = math.max(gameY + gameHeight + 8, height - 148)
			end
			self._playerControls.Position = UDim2.fromOffset(16, controlsY)
			self._playerControls.Size = UDim2.new(1, -32, 0, 148)
		end
	end
end

function Controller:_createPlayerControls(parent)
	local controls = make("Frame", {
		Name = "TouchControls",
		Size = UDim2.new(1, -32, 0, 148),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 6,
	}, parent)
	self._playerControls = controls
	local size = UDim2.fromOffset(40, 40)

	local function stateButton(labelText, position, methodName)
		local button = make("TextButton", {
			Name = labelText .. "State",
			Position = position,
			Size = UDim2.fromOffset(44, 24),
			BackgroundColor3 = Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
			Text = labelText,
			TextColor3 = Theme.Colors.Muted,
			TextSize = 8,
			Font = Theme.Fonts.Mono,
			AutoButtonColor = true,
			Selectable = false,
			ZIndex = 7,
		}, controls)
		addCorner(button, 7)
		self:_connect(button.Activated, function()
			local host = self._playerHost
			if host then
				host[methodName](host)
			end
		end, "player")
	end

	stateButton("SAVE", UDim2.new(0.5, -44, 0, 48), "SaveState")
	stateButton("LOAD", UDim2.new(0.5, 8, 0, 48), "LoadState")

	local function control(labelText, bit, position, color)
		local button = make("TextButton", {
			Name = "Touch_" .. labelText,
			Position = position,
			Size = size,
			BackgroundColor3 = color or Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
			Text = labelText,
			TextColor3 = Theme.Colors.Text,
			TextSize = 11,
			Font = Theme.Fonts.Bold,
			AutoButtonColor = false,
			Selectable = false,
			ZIndex = 7,
		}, controls)
		local cornerRadius = if labelText == "A" or labelText == "B" then 20 else 10
		if labelText == "SELECT" or labelText == "START" then
			button.Size = UDim2.fromOffset(52, 32)
		end
		addCorner(button, cornerRadius)
		addStroke(button, Theme.Colors.Border, 0.15, 1)
		self:_connect(button.InputBegan, function(inputObject)
			if inputObject.UserInputType == Enum.UserInputType.Touch
				or inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
				if self._playerHost then
					self._playerHost:Touch(button, bit, true)
				end
			end
		end, "player")
		self:_connect(button.InputEnded, function(inputObject)
			if inputObject.UserInputType == Enum.UserInputType.Touch
				or inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
				if self._playerHost then
					self._playerHost:Touch(button, bit, false)
				end
			end
		end, "player")
		return button
	end

	control("L", 9, UDim2.fromOffset(0, 2))
	control("↑", 6, UDim2.fromOffset(40, 42))
	control("←", 5, UDim2.fromOffset(0, 82))
	control("↓", 7, UDim2.fromOffset(40, 108))
	control("→", 4, UDim2.fromOffset(80, 82))
	control("SELECT", 2, UDim2.new(0.5, -52, 0, 10), Theme.Colors.Panel)
	control("START", 3, UDim2.new(0.5, 4, 0, 10), Theme.Colors.Panel)
	control("B", 1, UDim2.new(1, -90, 0, 100), Color3.fromRGB(93, 56, 62))
	control("A", 0, UDim2.new(1, -46, 0, 42), Theme.Colors.AccentDeep)
	control("R", 8, UDim2.new(1, -40, 0, 2))
	return controls
end

function Controller:_launchGBA(source)
	self:_closePlayer()
	self._sidebar.Visible = false
	self._main.Visible = false

	local overlay = make("Frame", {
		Name = "EmulatorPlayer",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, self._screen)
	self._playerOverlay = overlay
	make("UIGradient", {
		Rotation = 110,
		Color = ColorSequence.new(Theme.Colors.Background, Color3.fromRGB(16, 25, 31)),
		ZIndex = 5,
	}, overlay)

	local back = make("TextButton", {
		Name = "BackToLibrary",
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.fromOffset(92, 36),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		Text = "‹  LIBRARY",
		TextColor3 = Theme.Colors.Text,
		TextSize = 10,
		Font = Theme.Fonts.Bold,
		AutoButtonColor = true,
		ZIndex = 7,
	}, overlay)
	addCorner(back, 10)
	self:_connect(back.Activated, function()
		self:_closePlayer()
	end, "player")

	addLabel(overlay, "GBA  ·  DEPTH", UDim2.fromOffset(122, 11), UDim2.new(1, -248, 0, 22), {
		Color = Theme.Colors.Text,
		TextSize = 12,
		Font = Theme.Fonts.Bold,
		Truncate = true,
		ZIndex = 7,
	})
	local statusLabel = addLabel(overlay, "Starting Depth…", UDim2.fromOffset(122, 32), UDim2.new(1, -248, 0, 17), {
		Color = Theme.Colors.Accent,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		Truncate = true,
		ZIndex = 7,
	})
	self._playerStatus = statusLabel

	local pauseButton = make("TextButton", {
		Name = "PauseEmulation",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 14),
		Size = UDim2.fromOffset(88, 36),
		BackgroundColor3 = Theme.Colors.AccentDeep,
		BorderSizePixel = 0,
		Text = "PAUSE",
		TextColor3 = Theme.Colors.Accent,
		TextSize = 10,
		Font = Theme.Fonts.Bold,
		AutoButtonColor = false,
		Active = false,
		ZIndex = 7,
	}, overlay)
	addCorner(pauseButton, 10)
	self._playerPauseButton = pauseButton

	local viewport = make("Frame", {
		Name = "EmulatedDisplay",
		Position = UDim2.fromOffset(16, 72),
		Size = UDim2.fromOffset(360, 240),
		BackgroundColor3 = Color3.fromRGB(1, 3, 5),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 6,
	}, overlay)
	addCorner(viewport, 12)
	addStroke(viewport, Theme.Colors.Border, 0, 1)
	self._playerViewport = viewport

	local info = addLabel(viewport, "", UDim2.fromOffset(16, 10), UDim2.new(1, -32, 1, -20), {
		Color = Theme.Colors.Muted,
		TextSize = 12,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
		ZIndex = 9,
	})
	info.Visible = false
	self._playerInfo = info
	local metrics = addLabel(overlay, "", UDim2.fromOffset(16, 0), UDim2.new(1, -32, 0, 20), {
		Color = Theme.Colors.Muted,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		ZIndex = 7,
	})
	self._playerMetrics = metrics

	local saveButton = make("TextButton", {
		Name = "SaveState",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -100, 1, -12),
		Size = UDim2.fromOffset(72, 28),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		Text = "SAVE",
		TextColor3 = Theme.Colors.Text,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		AutoButtonColor = false,
		Active = false,
		Visible = not UserInputService.TouchEnabled,
		ZIndex = 7,
	}, overlay)
	addCorner(saveButton, 8)
	self._playerSaveButton = saveButton
	self:_connect(saveButton.Activated, function()
		if self._playerHost then
			self._playerHost:SaveState()
		end
	end, "player")

	local loadButton = make("TextButton", {
		Name = "LoadState",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -12),
		Size = UDim2.fromOffset(72, 28),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		Text = "RESTORE",
		TextColor3 = Theme.Colors.Text,
		TextSize = 9,
		Font = Theme.Fonts.Mono,
		AutoButtonColor = false,
		Active = false,
		Visible = not UserInputService.TouchEnabled,
		ZIndex = 7,
	}, overlay)
	addCorner(loadButton, 8)
	self._playerLoadButton = loadButton
	self:_connect(loadButton.Activated, function()
		if self._playerHost then
			self._playerHost:LoadState()
		end
	end, "player")

	self:_connect(overlay:GetPropertyChangedSignal("AbsoluteSize"), function()
		self:_layoutPlayer()
	end, "player")
	self:_layoutPlayer()

	local core = CoreRegistry.Get("gba")
	if not core then
		statusLabel.Text = "Depth core is not registered"
		info.Text = "The GBA core could not be loaded. Return to the library and check the client output."
		info.Visible = true
		return
	end

	local createOk, host = pcall(core.Create, {})
	local compatibleHost = createOk and type(host) == "table"
	if compatibleHost then
		for _, methodName in ipairs({ "Start", "Stop", "IsPaused", "IsRunning", "SetPaused", "Touch", "SaveState", "LoadState" }) do
			if type(host[methodName]) ~= "function" then
				compatibleHost = false
				break
			end
		end
	end
	if not compatibleHost then
		statusLabel.Text = "Depth core failed to initialize"
		info.Text = createOk and "The local core did not return a compatible host." or tostring(host)
		info.Visible = true
		return
	end
	self._playerHost = host
	self:_layoutPlayer()

	local startOk, started, result = pcall(host.Start, host, viewport, source, {
		onStatus = function(message)
			if self._playerStatus and self._playerStatus.Parent then
				self._playerStatus.Text = message
			end
			if self._playerPauseButton and self._playerPauseButton.Parent then
				local running = self._playerHost and self._playerHost:IsRunning()
				local paused = self._playerHost and self._playerHost:IsPaused()
				self._playerPauseButton.Text = if not running then "STOPPED" elseif paused then "RESUME" else "PAUSE"
				self._playerPauseButton.Active = running
				self._playerPauseButton.AutoButtonColor = running
			end
			if self._playerControls then
				self._playerControls.Visible = UserInputService.TouchEnabled and self._playerHost ~= nil
					and self._playerHost:IsRunning()
			end
			for _, button in ipairs({ self._playerSaveButton, self._playerLoadButton }) do
				if button and button.Parent then
					button.Active = running
					button.AutoButtonColor = running
				end
			end
		end,
		onMetrics = function(message)
			if self._playerMetrics and self._playerMetrics.Parent then
				self._playerMetrics.Text = message
			end
		end,
	})
	if not startOk then
		result = started
		started = false
	end
	if not started then
		pcall(host.Stop, host)
		self._playerHost = nil
		statusLabel.Text = "No game started"
		info.Text = tostring(result)
		info.Visible = true
		self:_layoutPlayer()
		return
	end

	info.Visible = false
	if UserInputService.TouchEnabled then
		self:_createPlayerControls(overlay)
		self:_layoutPlayer()
	end
	pauseButton.Active = true
	pauseButton.AutoButtonColor = true
	self:_connect(pauseButton.Activated, function()
		if not self._playerHost then
			return
		end
		local paused = not self._playerHost:IsPaused()
		self._playerHost:SetPaused(paused)
		pauseButton.Text = paused and "RESUME" or "PAUSE"
	end, "player")
	self._playerHost.input.onMenu = function()
		if self._playerHost then
			local paused = not self._playerHost:IsPaused()
			self._playerHost:SetPaused(paused)
			pauseButton.Text = paused and "RESUME" or "PAUSE"
		end
	end
end

function Controller:_closePlayer()
	self:_disconnectBucket(self._playerConnections)
	if self._playerHost then
		pcall(self._playerHost.Stop, self._playerHost)
		self._playerHost = nil
	end
	if self._playerOverlay then
		self._playerOverlay:Destroy()
		self._playerOverlay = nil
	end
	self._playerStatus = nil
	self._playerMetrics = nil
	self._playerViewport = nil
	self._playerControls = nil
	self._playerPauseButton = nil
	self._playerSaveButton = nil
	self._playerLoadButton = nil
	if self._main then
		self._main.Visible = true
	end
	if self._sidebar then
		self._sidebar.Visible = true
	end
	if self._screen then
		self:_applyResponsiveLayout()
	end
end

function Controller:_closeModal()
	self:_disconnectBucket(self._modalConnections)
	if self._modal then
		self._modal:Destroy()
		self._modal = nil
	end
end

function Controller:Destroy()
	self:_closePlayer()
	self:_closeModal()
	if self._avalonPreview then
		pcall(function()
			self._avalonPreview:destroy()
		end)
		self._avalonPreview = nil
	end
	self:_disconnectBucket(self._dynamicConnections)
	self:_disconnectBucket(self._connections)
	if self._cameraConnection then
		self._cameraConnection:Disconnect()
		self._cameraConnection = nil
	end
	if self._screen then
		self._screen:Destroy()
		self._screen = nil
	end
	self._started = false
end

return Controller
