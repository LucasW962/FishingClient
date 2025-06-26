local FishingClient = {}

local Client = require(script.Parent.Parent.Parent) --// THE CLIENT IS A PARENT OF THE PARENT, MODULE WITH A FEW HELPERS
local Mouse = Client.player:GetMouse()
local Library = require(game.ReplicatedStorage.Modules.Shared.LibraryYoda)
local FishingData = require(game.ReplicatedStorage.Modules.Minigames.Fishing) --// USEFUL FOR THE FISHING CONFIG DATA
local Character : typeof(game.ReplicatedStorage.RIG) = Client.player.character or Client.player.CharacterAdded:Wait()
local Fishing_Status = false
local CAN_FISH = true
local Fish_Timer = os.clock()

local FishingUI : typeof(Client.player.PlayerGui.FishingUI) = Client.player.PlayerGui:WaitForChild("FishingUI")

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")


--// LOCAL TYPES ALL BELOW

type FishingSession = {
	fishData: FishingData.FishDataType,
	iconPosition: number,
	fishPosition: number,
	targetPosition: number,
	progress: number,
	startTime: number,
	lastTargetChange: number,
	fishMovePattern: {FishMoveSegment},
	totalDuration: number?
}

type FishMoveSegment = {
	targetPos: number,
	duration: number,
	easing: string
}

type ValidationResult = {
	success: boolean,
	reason: string
}

type StatusResults = {
	SUCCESS: number,
	NOT_FISHING_ZONE: number,
	TOO_FAR: number
}

type PhysicsState = {
	clickVelocity: number,
	isClicking: boolean,
	currentGravity: number,
	fallTime: number
}

type AnimationTracks = {
	hold: AnimationTrack?,
	throw: AnimationTrack?,
	waiting: AnimationTrack?,
	reeling: AnimationTrack?,
	caught: AnimationTrack?
}

type InputConnections = {
	mouseDown: RBXScriptConnection?,
	mouseUp: RBXScriptConnection?,
	touchStart: RBXScriptConnection?,
	touchEnd: RBXScriptConnection?
}

--// STATE TRACKING VARS
local currentFishingSession: FishingSession? = nil
local isFishReeling = false
local lastDeltaTime = 0

--// TRACKS THE PHYSIC STATE
local physicsState: PhysicsState = {
	clickVelocity = 0,
	isClicking = false,
	currentGravity = 0,
	fallTime = 0
}

--// ALL OF MY UI ELEMENTS HERE
local FishingLevel = FishingUI.FishingLevel
local FishingFolder = Client.player:WaitForChild("Fishing") :: Folder
local Strength_UI = FishingUI.Strength
local Camera = workspace.CurrentCamera
local Holder = FishingUI.Holder
local Bar_Holder = Holder.Bar_Holder
local Icon = Bar_Holder.Icon
local Fish_Icon = Bar_Holder.Fish
local Progress_Bar = Holder.Progress_Holder.Progress

--// ANIMATIONS HERE, TABLE OF ANIMATIONS TOO
local AnimationsFolder = game.ReplicatedStorage.Animations.Fishing
local animations: AnimationTracks = {
	hold = nil,
	throw = nil,
	waiting = nil,
	reeling = nil,
	caught = nil
}

--// THESE VARIABLES ARE FOR CHARGING THE FISHING ROD, NOT CONSTANTS
local isCharging = false
local chargeStartTime = 0
local throwPower = 0
local throwPowerUI = Strength_UI.Bar
local isIncreasing = true

--// THESE ARE THE CONSTANTS FOR THE FISHING GAME
local BASE_GRAVITY = 0.001   --// GRAVITY THAT MAKES THE FISHING ROD DROP AUTO
local MAX_GRAVITY = 0.012    --// CLAMPED VALUE SO IT CANT GO PASS THIS
local GRAVITY_ACCEL = 0.015 --// ADD THE GRAVITY VAL PER FRAME
local CLICK_POWER_INITIAL = 0.00056 --// THIS IS IN A LOOP, STOP THE GRAVITY ACCEL AND APPLIES -GRAVITY
local CLICK_DECAY = 0.01 --// ACTS LIKE A SPRING DAMPENER 
local MAX_PROGRESS = 100 --// MAX PROGRESS BAR VALUE
local PROGRESS_INCREASE_RATE = 0.3 --// PROGRESS INCREASE EACH TICK WHILE THE BAR IS OVER THE FISH
local PROGRESS_DECREASE_RATE = 0.21 --// DECREASE RATE FOR WHEN THE BAR IS NOT ON THE FISH, AND AFTER THE INITAL IMMUNITY
local MAX_THROW_PERCENT = 100 --// MAX IT CAN GO TO FOR A THROW
local STARTING_IMMUNITY_SECONDS = 5 --// INITAL IMMUNITY SO THEY DONT INSTANTLY LOSE

local statusResults: StatusResults = { --// ENUM MAPPING TABLE
	SUCCESS = 0,
	NOT_FISHING_ZONE = 1,
	TOO_FAR = 2
}

--// HELPER TO RETURN AND LOAD ALL THE ANIM TRACKS
local function createAnimationTracks(animator: Animator): AnimationTracks
	return {
		hold = animator:LoadAnimation(AnimationsFolder.Hold),
		throw = animator:LoadAnimation(AnimationsFolder.Throw),
		waiting = animator:LoadAnimation(AnimationsFolder.Waiting),
		reeling = animator:LoadAnimation(AnimationsFolder.Reeling),
		caught = animator:LoadAnimation(AnimationsFolder.Caught)
	}
end

--// SET THE NEEDED ANIMS TO LOOPING BASED ON IF THEYRE LOADED OR NOT
local function configureAnimationLooping(tracks: AnimationTracks)
	if tracks.hold then tracks.hold.Looped = true end
	if tracks.waiting then tracks.waiting.Looped = true end
	if tracks.reeling then tracks.reeling.Looped = true end
end


--// HELPER FUNC TO DETERMINE IF THE USER CAN ACTIVELY FISH OR NOT
local function validateFishingRequirements(): ValidationResult
	if Client.player:GetAttribute("Fishing") then 
		return {success = false, reason = "Already fishing"} --// THE USER IS FISHING SO THEY CANT FISH TWICE
	end

	local HasRod = Library:FishingRod_Status(Character) --// THIS FUNC JUST CHECKS THEIR USER FOR A FISHING ROD, BACKPACK/CHAR
	if not HasRod then
		Library:CreateAlert(Client.player, "I need a fishing rod to fish!") --// GIVE A WARNING
		return {success = false, reason = "No rod"}
	end

	if not CAN_FISH then
		local timeRemaining = math.ceil(Fish_Timer + 5 - os.clock()) --// A TIMER TO WARN THEM THEY CAN ONLY DO AN ATTEMPT EVERY 5 SECONDS
		Library:CreateAlert(Client.player, "I can fish again in " .. timeRemaining .. " seconds")
		return {success = false, reason = "Cooldown"}
	end

	return {success = true, reason = "Valid"} --// FISHING IS VALID
end

local function calculateThrowPowerColor(normalizedPower: number): Color3 --// FUNCTION FOR UI
	local green = Color3.fromRGB(0, 255, 0)
	local yellow = Color3.fromRGB(255, 255, 0)
	local red = Color3.fromRGB(255, 0, 0)

	return normalizedPower < 0.5 
		and green:Lerp(yellow, normalizedPower * 2) --// I USED MANUAL LERP BEFORE LEARNING MANUAL HAD 4 INSTRUCTIONS OF BYTECODE VS ROBLOXS 5 INSTRUCTION BYTECODE
		or yellow:Lerp(red, (normalizedPower - 0.5) * 2) --// RETURN THE COLOR3
end

local function updateThrowPowerState(deltaTime: number) --// DETERMINE THE THROW POWER STATE 
	if isIncreasing then
		throwPower = math.min(throwPower + (deltaTime * 50), MAX_THROW_PERCENT) 
		if throwPower >= MAX_THROW_PERCENT then
			isIncreasing = false 
		end
	else --// POWER IS DROPPING, USE DT TO MULTIPLY BY IT AT A DECREASING RATIO
		throwPower = math.max(throwPower - (deltaTime * 50), 0) 
		if throwPower <= 0 then
			isIncreasing = true 
		end
	end
end

local function updateThrowPowerUI() --// UPDATE THE SIZING OF THE BAR TO SHOW THE THROW POWER CHANGE TO THE CLIENT
	local yScale = (throwPower / MAX_THROW_PERCENT) * 0.989
	throwPowerUI.Size = UDim2.fromScale(0.898, yScale) --// SET THE SCALE

	local normalizedPower = throwPower / MAX_THROW_PERCENT --// DIVIDE IT BY THE MAX TO DETERMINE THE COLOR OF THE BACKGROUND
	throwPowerUI.BackgroundColor3 = calculateThrowPowerColor(normalizedPower)
end

local function initializeChargingUI() --// HELPER TO INIT THE NEW BAR, USED FOR WHEN FISHING ENDS
	Strength_UI.Visible = true
	throwPowerUI.Size = UDim2.new(0.898, 0, 0, 0) 
	throwPower = 0
	isIncreasing = true
end

local function setupCharacterMovementRestrictions() --// CHARACTER HELPER, SETS RESTRICTIONS FOR WHEN FISHING STARTS
	Character.Humanoid.WalkSpeed = 0
	Character.Humanoid.JumpPower = 0
	Character.Humanoid.JumpHeight = 0
	Character.Humanoid.AutoJumpEnabled = false
end

local function restoreCharacterMovement() --// HELPER TO GIVE THE CHARACTER ITS MOVEMENT BACK
	Character.Humanoid.WalkSpeed = 16
	Character.Humanoid.JumpPower = 50
	Character.Humanoid.JumpHeight = 7.2
	Character.Humanoid.AutoJumpEnabled = true
end

local function resetPhysicsState() --// RESET ALL THE NON CONSTANT VARIABLES WHEN FISHING ENDS
	physicsState.clickVelocity = 0
	physicsState.isClicking = false
	physicsState.currentGravity = 0
	physicsState.fallTime = 0
end

local function initializeFishingSession(fishData: FishingData.FishDataType): FishingSession
	isFishReeling = true
	lastDeltaTime = 0
	resetPhysicsState()

	FishingUI.Enabled = true
	Holder.Visible = true
	Progress_Bar.Size = UDim2.new(0.898, 0, 0, 0)

	return { --// THE FISH DATA IS FROM THE SERVER, WE INIT IT TO GET THE DATA AND PATTERN CHANGES FROM SERVER
		fishData = fishData,
		iconPosition = 0.5,
		fishPosition = 0.5,
		targetPosition = 0.5,
		progress = 0,
		startTime = os.clock(),
		lastTargetChange = 0,
		fishMovePattern = {}
	}
end

local function calculateUIScales(fishStrength: number): (number, number) --// DETERMINE HOW THE UI SHOULD SCALE BASED ON THE FISH STRENGTH, ICON SIZING TOO
	local iconScale = math.max(0.6, 1 - (fishStrength * 0.02))
	local fishScale = math.max(0.4, 1 - (fishStrength * 0.015))
	return iconScale, fishScale
end

local function setupFishUI(fishData: FishingData.FishDataType) -- INIT THE UI BASED ON THE SERVERS FISHDATA INFO 
	local fishStrength = fishData.Strength --// SET REFERENCES
	local fishName = fishData.Name
	local fishRarity = fishData.Rarity

	local baseIconSize = UDim2.new(1, 0, 0.276, 0)
	local baseFishSize = UDim2.new(1, 0, 0.131, 0)

	local iconScale, fishScale = calculateUIScales(fishStrength)

	Icon.Size = UDim2.new( --// SET THE SCALING
		baseIconSize.X.Scale * iconScale,
		baseIconSize.X.Offset,
		baseIconSize.Y.Scale * iconScale,
		baseIconSize.Y.Offset
	)

	Fish_Icon.Size = UDim2.new( --// SET THEW SCALING
		baseFishSize.X.Scale * fishScale,
		baseFishSize.X.Offset,
		baseFishSize.Y.Scale * fishScale,
		baseFishSize.Y.Offset
	)

	Fish_Icon.Image = FishingData.RarityInfo[fishRarity].ImageID --// GET THE IMAGEID WITH A LOOKUP TABLE BASED ON RARITY WITH OUR SHARED TABLE
	Holder.FishInfo.Text = fishName .. " (" .. fishRarity .. ")"
	Holder.FishInfo.Visible = true
end

local function updateClickPhysics(deltaTime: number, fishStrength: number) --// THIS IS FOR THE CLICKING PHYSICS
	if physicsState.isClicking then
		local strengthFactor = 1 / (fishStrength * 0.08 + 1) --// BASE FORMULA FOR DETERMINE THE STRENGTH OF THE CLICK, USING THE FISH AND VELOCITY
		physicsState.clickVelocity = math.min(
			physicsState.clickVelocity + (CLICK_POWER_INITIAL * strengthFactor), --// SET THE VELOCITY USING OUR CONST VAR AND STRENGTH FACTOR 
			0.04
		)
		physicsState.fallTime = 0 --// SET FALLTIME BACK TO 0, AS EACH CLICK WILL RESET THE BUILD UP VEL OF THE FALL
	else
		physicsState.clickVelocity = physicsState.clickVelocity * CLICK_DECAY
		physicsState.fallTime = physicsState.fallTime + deltaTime --// FALL TIME GETS FASTER

		physicsState.currentGravity = math.min( --// GRAVITY GETS HIGHER THE LONGER YOU DONT CLICK
			BASE_GRAVITY + (physicsState.fallTime * GRAVITY_ACCEL), 
			MAX_GRAVITY
		)
	end
end

local function calculateIconBounds(): (number, number) --// SET THE BOUNDS SO  THE ICON CANT GO OUT OF BOUNDS BY EITHER GRAVITY OR GOING TOO FAR
	local iconRelativeHeight = Icon.Size.Y.Scale / 2
	return iconRelativeHeight, 1 - iconRelativeHeight
end

local function updateIconPosition(deltaTime: number, session: FishingSession) --// USED TO UPDATE THE ICON POSITION
	local minIconPos, maxIconPos = calculateIconBounds() --// FIRST THE ICON BOUNDS

	session.iconPosition = session.iconPosition - physicsState.clickVelocity * (deltaTime * 60) --// USE THE CLICK VELOCITY MUL BY DT AND 60 TO DETERMINE THE NEW POS
	session.iconPosition = session.iconPosition + physicsState.currentGravity * (deltaTime * 60) --// SAME THING WITH CURRENT GRAVITY
	session.iconPosition = math.clamp(session.iconPosition, minIconPos, maxIconPos) --// THEN CLAMP THEM TOGETHER WITH THE MIN AND MAX WE GOT FOR THE RELATIVE HEIGHTS

	Icon.Position = UDim2.new(0.5, 0, session.iconPosition, 0) --// SET IT TO THESE POSITION AND THE MIDDLE
end

local function calculateFishBounds(): (number, number) --// HELPER TO DETERMINE THE FISH BOUNDS, SAME THING AS ICON BUT WITH THE FISH SIZINGS
	local fishRelativeHeight = Fish_Icon.Size.Y.Scale / 2
	return fishRelativeHeight, 1 - fishRelativeHeight
end

local function calculateEasedProgress(progress: number, easingType: string): number --// CALCULATE THE EASING PROGRESS THE FISH WILL USE
	if easingType == "sharp" then
		return progress < 0.5 and (2 * progress * progress) or (1 - math.pow(-2 * progress + 2, 2) / 2) --// TENTRARY TO DETERMINE HOW THE PROGRESS WSHOULD BE RETURNED
	end
	return progress --// RETURN NORMAL PROGRESS IF NOT SHARP
end

local function updateFishPosition(deltaTime: number, session: FishingSession) --// UPDATE THE FISH POSITION
	local elapsed = os.clock() - session.startTime --// GET THE ELASPED
	local minFishPos, maxFishPos = calculateFishBounds() --// GET THE FISH BOUNDS

	local currentTime = 0
	for _, segment in session.fishMovePattern do
		if currentTime <= elapsed and currentTime + segment.duration > elapsed then --// UGLY OPERATION BUT IT WORKS
			local segmentElapsed = elapsed - currentTime --// GET THAT SEGMENTS ELPASED TIME
			local progress = segmentElapsed / segment.duration
			local easedProgress = calculateEasedProgress(progress, segment.easing)

			local moveSpeed = 3 * (session.fishData.Strength * 0.1 + 0.5) --// SET THE MOVE SPEED, BASED ON THE FISH STRENGTH, BUT USING A BASE OF 3
			session.fishPosition = session.fishPosition + (segment.targetPos - session.fishPosition) * (deltaTime * moveSpeed) --// UPDATE THE FISH POS USING ALL RELEVANT INFO
			break
		end
		currentTime = currentTime + segment.duration
	end

	session.fishPosition = math.clamp(session.fishPosition, minFishPos, maxFishPos)
	Fish_Icon.Position = UDim2.new(0.5, 0, session.fishPosition, 0) --// SET THE NEW FISH POSITION
end

local function calculateOverlapThreshold(session: FishingSession): number --// USED TO DETERMINE IF THE ICON IS OVER THE FISH OR NOT BASED ON ALL DATA
	local iconSize = Icon.AbsoluteSize.Y
	local fishSize = Fish_Icon.AbsoluteSize.Y --// GET THE SIZINGS
	local strengthFactor = 1 / (session.fishData.Strength * 0.02 + 1) --// WE NEED THE FISH STRENGTH HERE, AS THE BIG ONES ARE SMALLER, DIFF THRESHOLDS
	return (iconSize + fishSize) * 0.25 * strengthFactor 
end

local function checkOverlap(session: FishingSession): boolean --// CHECK THE OVERLAPPING TO APPLY PROGRESS OR NOT
	local iconPos = Icon.AbsolutePosition.Y
	local fishPos = Fish_Icon.AbsolutePosition.Y --// GET ALL ABSOLUTE SIZINGS OFG EACH ICON AND FISH POS AND SIZE
	local iconSize = Icon.AbsoluteSize.Y
	local fishSize = Fish_Icon.AbsoluteSize.Y

	local iconCenter = iconPos + (iconSize / 2)
	local fishCenter = fishPos + (fishSize / 2) --// GET CENTERS
	local overlapThreshold = calculateOverlapThreshold(session) --// CHECK OVERLAPS

	return math.abs(iconCenter - fishCenter) < overlapThreshold --// RETURN THE ABS VALUE OF THE CENTER BEING LESS THAN THE THRESHOLD OR NOT, IF TRUE THEN YYES, WE ARE OVERLAPPING AND APPLY PROGRESS
end

local function updateProgress(session: FishingSession) --// UPDATE THE PROGRES
	local isOverlapping = checkOverlap(session) --// USING THE PREVIOUS FUNCTION, WE GET A BOOLEAN

	if isOverlapping then
		local progressRate = PROGRESS_INCREASE_RATE * (1.1 - (session.fishData.Strength * 0.005)) --// START APPLYING PROGRESS, WE USE THE STRENGTH TO APPLY A DECAY VALUE TO TOTAL PROGRESS
		session.progress = math.min(MAX_PROGRESS, session.progress + progressRate)
	else
		local decreaseRate = PROGRESS_DECREASE_RATE * (0.9 + (session.fishData.Strength * 0.005)) --// DECREASE RATE FOR PROGRESS
		session.progress = math.max(0, session.progress - decreaseRate)
	end

	Progress_Bar.Size = UDim2.new(0.898, 0, session.progress / MAX_PROGRESS, 0) --// SET THE BAR SIZE BASED ON PROGRESS, HIGHER PROGRESS IS MORE SIZING
end

local function isValidFishingInput(input: InputObject): boolean --// SMALL HELPER TO DETERMINE IF THE INPUT TYPE IS VALID TYPE FOR FISHING OR NOT, IF TRUE THEN VALID
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch or input.KeyCode == Enum.KeyCode.Space
end

local function createInputConnection<T...>(event: RBXScriptSignal<T...>, handler: (T...) -> ()): RBXScriptConnection --// Small helper function for setting up input connectors with callbacks
	return event:Connect(handler)
end

local function setupFishingInputConnections(session: FishingSession): () -> () --// USED TO SET UP THE INPUT CONNS FOR FISHING
	local connections: {RBXScriptConnection} = {}

	local inputBeganHandler = function(input: InputObject, gameProcessed: boolean)
		if not isFishReeling or gameProcessed then return end

		if isValidFishingInput(input) then --// FIRST VALIDATE THE INPUT TYPE
			physicsState.isClicking = true
			physicsState.clickVelocity = math.max(
				physicsState.clickVelocity,  
				CLICK_POWER_INITIAL * (1 + session.fishData.Strength * 0.03) --// SET OUR VELOCITY OF THE CLICK, USING THE STRENGTH AND A BASE OF OUR CONST VAL AND THE FISH STRENGTH
			)
			physicsState.fallTime = 0 --// SET FALL TIME BAACK TO 0 TO RESET PHYSIC STATE
		end
	end

	local inputEndedHandler = function(input: InputObject)
		if isValidFishingInput(input) then
			physicsState.isClicking = false --// CLICKING STOPPED
		end
	end

	table.insert(connections, createInputConnection(UserInputService.InputBegan, inputBeganHandler)) --// INPUT TO OUR CONNECTIONS WITH THE CALLBACK FOR THE FUNCTIONS
	table.insert(connections, createInputConnection(UserInputService.InputEnded, inputEndedHandler))

	return function()
		for _, connection in connections do
			connection:Disconnect() --// RETURN A FUNCTION THAT WILL SOTP ALL CONNECTIONS IF I NEED IT
		end
	end
end

local function generateFishMovePattern(strength: number): {FishMoveSegment} --// THIS FUNCTION IS FOR GENERATING RANDOM FISH MOVEMENTS
	local pattern: {FishMoveSegment} = {} --// INIT EMPTY TABLE BUT GIVE THE TYPE REFS
	local duration = 999 + math.min(30, strength * 2) 
	local changeFrequency = math.max(0.5, 2 - (strength * 0.1))

	local time = 0
	while time < duration do --// WHILE WE ARE ACTIVELY PLAYING, WE GENERATE A SEGMENT 
		local segmentDuration = math.random() * changeFrequency + 0.3
		table.insert(pattern, {
			targetPos = math.random() * 0.8 + 0.1,
			duration = segmentDuration,
			easing = math.random() > 0.7 and "sharp" or "smooth" --// IF THE MOVEMENT WAS GREATER THAN 0.7 (30%), ITS A FASTER TURN, LOOKS MORE RIGID AND FASTER
		})
		time = time + segmentDuration --// UPDATE THE TIME SO THE FISH HAS A SMALL BREAK BEFORE MOVING AGAIN
	end

	return pattern
end

local function playAnimation(animTrack: AnimationTrack?) --// PLAY A CERTAIN ANIM
	if animTrack then
		animTrack:Play()
	end
end

local function stopAnimation(animTrack: AnimationTrack?) --// STOP A CERTIAN ANIM
	if animTrack then
		animTrack:Stop()
	end
end

local function calculateCastSuccess(): boolean --// RETURN WETHER OR NOT THE CAST WAS SUCCESS AND ALLOW THE USER TO FISH OR NOT
	local successChance = 0.3 + (throwPower / MAX_THROW_PERCENT) * 0.7
	return math.random() < successChance
end

local function handleCastResult(success: boolean) --// RETURN TRUE OR NOT IF THE USER CASTED
	if success then
		Fishing_Status = true
		game.ReplicatedStorage.Events.StartFishing:FireServer("Join") --// LET THE SERVER KNOW THE USER IS NOW FISHING, INSERT THEM INTO A TABLE ON THE SERVER
	else
		Library:CreateAlert(Client.player, "My cast wasn't good enough. Let me try again.")
		task.delay(1.5, function()
			stopAnimation(animations.waiting) --// STOP THE ANIM AFTER 1.5 SECS
		end)
	end
end

local function createTweenForXpBar(target: GuiObject, targetSize: UDim2): Tween --// TWEEN TO LET THE USER KNOW THEY GOT XP
	local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) --// I WOULD HAVE USED MY SPRING MODULE BUT THIS SCRIPT WAS MADE BEFORE I MADE IT
	return TweenService:Create(target, tweenInfo, {Size = targetSize})
end

local function calculateXpProgress(currentXp: number, nextLevelXp: number): number --// RETURN XP PROGRESS
	return math.clamp(currentXp / nextLevelXp, 0, 1)
end

local function handleMouseDown() --// FOR NORMAL MOUSE CLICK, NOT A LOOP OR ANYTHING, JUST A HELPER TO DETERMINE IF THEY HAVE A FISHING ROD OR, IF SO THEN START FISHING.
	local HasRod = Library:FishingRod_Status(Character)
	if HasRod and not Client.player:GetAttribute("Fishing") then
		FishingClient:StartFishing(Mouse.Target)
	end
end

local function handleMouseUp() --// CASTING IS DONE WHEN THE MOUSE IS RELEASED (FOR REELS)
	if isCharging then
		FishingClient:CompleteCast()
	end
end

local function handleTouchStart(touch: InputObject, gameProcessed: boolean) --// THIS IS FOR MY MOBILE FRIENDS
	if gameProcessed then return end

	local HasRod = Library:FishingRod_Status(Character)
	if not HasRod or Client.player:GetAttribute("Fishing") then return end --// CHECKS IF THEY CAN FISH OR NOT

	local touchPosition = touch.Position
	local unitRay = Camera:ScreenPointToRay(touchPosition.X, touchPosition.Y) --// CHECKS WHERE THEY TOUCHED AND RETURN IT AS A RAY

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {Character}

	local raycastResult = workspace:Raycast(unitRay.Origin, unitRay.Direction * 100, raycastParams)
	local hitPart = raycastResult and raycastResult.Instance or nil

	FishingClient:StartFishing(hitPart) --// START FISHING IF EVERYTHING WAS GOOD
end


local function handleTouchEnd(touch: InputObject, gameProcessed: boolean) --// CHECKS WHEN THE TOUCH ENDS
	if gameProcessed then return end
	if isCharging then
		FishingClient:CompleteCast() --// COMPLETE THE CAST IF CHARGING WAS TRUE
	end
end

local function disconnectInputConnections(connections: InputConnections) --// END ALL INPUTS
	for _, connection in connections do
		if connection then
			connection:Disconnect() --// DISCONNECT IF IT EXISTS
		end
	end
end

local function createInputConnections(): InputConnections --// CREATE ALL USEFUL INPUTS
	return {
		mouseDown = createInputConnection(Mouse.Button1Down, handleMouseDown),
		mouseUp = createInputConnection(Mouse.Button1Up, handleMouseUp),
		touchStart = createInputConnection(UserInputService.TouchStarted, handleTouchStart),
		touchEnd = createInputConnection(UserInputService.TouchEnded, handleTouchEnd)
	}
end

function FishingClient.SetupAnimations() --// SET UP ALL ANIMS FOR THE CHARACTER, THIS IS A USEFUL FUNCTIONS FOR INIT, AND CHAR RELOAD
	if not Character then return end

	local animator = Character.Humanoid:FindFirstChildOfClass("Animator") :: Animator
	animator.Parent = Character.Humanoid

	animations = createAnimationTracks(animator)
	configureAnimationLooping(animations)
end

function FishingClient.CheckStatus(partName: string): number --// CHECKS IF THE USER IS IN A FISHING ZONE OR NOT
	if partName ~= "FishingZone" then
		return statusResults.NOT_FISHING_ZONE --// RETURN THE ERROR RESULT
	end

	local hitPart = Mouse.Target
	if not hitPart or hitPart.Name ~= "FishingZone" then
		return statusResults.NOT_FISHING_ZONE --// CHECK WHERE THEIR MOUSE IS POSITIONED
	end

	local playerPosition = Character.PrimaryPart.Position
	local shortestDistance = FishingClient.GetDistanceToZone(playerPosition, hitPart)

	return shortestDistance <= 10 and statusResults.SUCCESS or statusResults.TOO_FAR --// RETURN A VAR IF THEIR TOUCH FROM THE ZONE IS ATLEAST 10 STUDS OR NOT
end

function FishingClient.GetDistanceToZone(point: Vector3, part: BasePart): number
	local size = part.Size
	local cf = part.CFrame

	local relative = cf:PointToObjectSpace(point) --// CONVERT THE WORLD CFRAME TO A LOCAL CFRAME SPACE TO THAT PART

	local closest = Vector3.new(
		math.clamp(relative.X, -size.X/2, size.X/2),
		math.clamp(relative.Y, -size.Y/2, size.Y/2),
		math.clamp(relative.Z, -size.Z/2, size.Z/2)
	)

	local closestWorld = cf:PointToWorldSpace(closest) --// RETURN IT TO A WORLD SPACE WITH THE MAGNITUDE FROM POINT TO THE WORLD CFRAME
	return (point - closestWorld).Magnitude
end

function FishingClient.StartFishing(target: BasePart?) --// FUNC TO START FISHING
	local validation = validateFishingRequirements() --// CHECK IF VALIDATION IS TRUE OR NOT, RETURN IF NOT TRUE
	if not validation.success then return end

	if target then
		local status = FishingClient.CheckStatus(target.Name)

		if status == statusResults.TOO_FAR then --// IF THEYRE TOO FAR, THEN THEY GET AN ERROR WHY
			Library:CreateAlert(Client.player, "I need to be closer to the fishing spot!")
			return
		elseif status == statusResults.NOT_FISHING_ZONE then --// SAME IF THEYRE NOT IN A FISHING ZONE OR NOT 
			Library:CreateAlert(Client.player, "I can only fish at fishing spots!")
			return
		end
	end

	initializeChargingUI() --// START THE FISHING UI, AND PLAY THE ANIMS 
	playAnimation(animations.hold)

	isCharging = true
	chargeStartTime = os.clock() --// STOIRE THE START TIME
	
	local chargeConn : RBXScriptConnection?
	
	chargeConn = RunService.PostSimulation:Connect(function(deltaTime)
		if not isCharging then
			chargeConn:Disconnect() --// DISCONENCT IF CHARGING IS NO LONGER TRUE, USELESS LOOP
			return
		end

		updateThrowPowerState(deltaTime) --// UPDATE THE UI AND STATUS
		updateThrowPowerUI()
	end)
end

function FishingClient.CompleteCast() --// FINISH CASTING
	if not isCharging then return end

	isCharging = false
	Strength_UI.Visible = false

	stopAnimation(animations.hold) --// STOP THE ANIM

	if not animations.throw then return end

	playAnimation(animations.throw)

	task.delay(animations.throw.Length * 0.7, function() --// DELAY THE LENGTH TO PLAY A NEW ANIM
		playAnimation(animations.waiting)

		local castSuccess = calculateCastSuccess()
		handleCastResult(castSuccess)
	end)
end

function FishingClient.PlayCatchAnimation() --// HELPER TO PLAY A CATCH ANIM FOR WHEN A FISH IS CAUGHT
	stopAnimation(animations.waiting)
	stopAnimation(animations.reeling)
	playAnimation(animations.caught)
end

function FishingClient.Fishing_UI(fishData: FishingData.FishDataType) --// FOR ALL OF THE FISHING UI, MAIN BLOCK 
	if isFishReeling then return end 

	stopAnimation(animations.waiting)
	playAnimation(animations.reeling) --// START AND PLAY NEEDED ANIMS 

	setupCharacterMovementRestrictions()
	Client.player:SetAttribute("Fishing", true) --// SET THEIR ATTRIBUTE TO TRUE SO THEY CANT FISH MORE THAN ONCE, VALIDATED ON THE SERVER WITH TABLES SO SETTING THIS ON CLIENT IS FINE

	currentFishingSession = initializeFishingSession(fishData)
	setupFishUI(fishData)

	currentFishingSession.fishMovePattern = generateFishMovePattern(fishData.Strength) --// START A PATTERN USING THE FISHDATA STRENGTH (GIVEN BY THE SERVER)

	local cleanupInput = setupFishingInputConnections(currentFishingSession) --// SET UP THE INPUTS WHEN FISHING STARTS

	local failureConnection: RBXScriptConnection?
	task.delay(STARTING_IMMUNITY_SECONDS, function() --// DELAY THE IMMUNITY TIME
		if Client.player:GetAttribute("Fishing") ~= true then return end --// IF THEYRE NO LONGER FISHING, THIS ISNT NEEDED TO CHECK ANYMORE

		failureConnection = RunService.RenderStepped:Connect(function()
			if currentFishingSession and currentFishingSession.progress <= 0 then
				FishingClient.EndFishing(false) --// END FISHING IF PROGRESS DROPS BELOW 0 AFTER THIS POINT
			end
		end)
	end)
	
	local conn : RBXScriptConnection?

	conn = RunService.PostSimulation:Connect(function(deltaTime)
		if not isFishReeling then
			if failureConnection then
				failureConnection:Disconnect() --// FAILURE OCNNECTION SHOULD END IF WERE NO LONGER IN MAIN LOOP
			end
			conn:Disconnect()
			cleanupInput() --// CLEAN UP THESE CONNS TO AND INPUTS
			return
		end

		lastDeltaTime = deltaTime
		FishingClient.UpdateFishing(deltaTime) --// IF WERE STILL FISHING, CALL THE FUNC TO UPDATE FISHING
	end)

	task.delay(1, function()
		if isFishReeling then
			Library:CreateAlert(Client.player, "I've got a bite! Reel it in!")
		end
	end)
end

function FishingClient.UpdateFishing(deltaTime: number) --// ANOTHER MAIN FUNCTION
	local session = currentFishingSession
	if not session then return end

	updateClickPhysics(deltaTime, session.fishData.Strength)
	updateIconPosition(deltaTime, session)
	updateFishPosition(deltaTime, session)
	updateProgress(session) --// CALL ALL HELPER FUNCTIONS TO UPDATE THE FISH, ICON, AND THE PHYSICS

	if session.progress >= MAX_PROGRESS then
		FishingClient.EndFishing(true) --// END FISHING WITH A TRUE VAR WHEN WE COMPLETED FISHING, I HAVE SERVER SIDED VALIDATION BTW
	end
end

function FishingClient.EndFishing(success: boolean) --// END FISHING FUNC, SUCCESS IS A BOOL BASED ON IF ITS SUCCESS OR NOT
	if not isFishReeling then return end

	CAN_FISH = false
	Fish_Timer = os.clock()

	task.delay(5, function()
		CAN_FISH = true
	end)

	restoreCharacterMovement()
	isFishReeling = false
	Holder.Visible = false

	if success and currentFishingSession then
		local fishName = currentFishingSession.fishData.Name
		local fishRarity = currentFishingSession.fishData.Rarity
		Library:CreateAlert(Client.player, "Caught a " .. fishRarity .. " " .. fishName .. "!") --// NOTIFY CLIENT ON THEIR CATCH 
	else
		Library:CreateAlert(Client.player, "The fish got away...")
	end

	FishingClient.PlayCatchAnimation() --// PLAY REEL ANIM 

	game.ReplicatedStorage.Events.StartFishing:FireServer("Complete", {
		success = success, --// FIRE THE SERVER SAYING WE FINISHED WITH THE STATUS
	})

	currentFishingSession = nil
	Client.player:SetAttribute("Fishing", false) --// NO LONGER FISHING, RESET ATTRIBUTE STATE
end

function FishingClient.LerpXpBar() --// LERP THE BAR BASED ON OUR NEW XP VALUE FROM THE SERVER
	local newXp = FishingFolder.XP.Value
	local nextLevel = Library:Fishing_XpToLevelCalc(Client.player)
	local xpBar = FishingLevel.Bar

	local progress = calculateXpProgress(newXp, nextLevel)
	local maxSize = UDim2.fromScale(.962, .712)
	local targetSize = UDim2.fromScale(maxSize.X.Scale * progress, maxSize.Y.Scale)

	local tween = createTweenForXpBar(xpBar, targetSize)
	tween:Play()

	FishingLevel.FishingXP.Text = math.floor(newXp) .. "/"..math.floor(nextLevel)
end

local function setupInputHandlers() --// MAIN FUNC TO SET UP ALL THE INPUTS
	local connections = createInputConnections()

	FishingClient.inputConnections = connections
end

FishingClient.SetupAnimations() --// CALL THE FUNCTIONS NEEDS
FishingClient.LerpXpBar()

FishingLevel.FishingLevel.Text = "Level: "..FishingFolder.Level.Value --// INIT THE UI

FishingFolder.Level.Changed:Connect(function() --// ON CHANG, CHANGE THE UI
	FishingLevel.FishingLevel.Text = "Level: "..FishingFolder.Level.Value
end)

FishingFolder.XP.Changed:Connect(function() --// ON CHANGE, LERP THE XP BAR OT NEW VLAUEAS
	FishingClient.LerpXpBar()
end)

game.ReplicatedStorage.Events.StartFishing.OnClientEvent:Connect(function(Action: string, fishData: FishingData.FishDataType?)
	if Action == "Start" then
		FishingClient.Fishing_UI(fishData) --// WHEN SERVER TELL CLIENT TO START, CALL THE UI
	end
end)

Client.player.CharacterAdded:Connect(function(character: typeof(game.ReplicatedStorage.RIG))
	Character = character
	FishingClient.SetupAnimations() --// RESET THE CHAR 
end)

Character.Zone:GetPropertyChangedSignal("Value"):Connect(function()
	FishingLevel.Visible = Character.Zone.Value == "Docks"
end)

setupInputHandlers()

return FishingClient
