-- Procedural Animator Class
-- Dthecoolest (optimized + vector library migration)

local RunService: RunService = game:GetService("RunService")

type Vector = vector

type LegData = {
	CurrentCycle: number,
	LimbChain: any?,
	CCDIKController: any,
	HipAttachment: Attachment,
	FootAttachment: Attachment,
	StrideCF: CFrame?,
	StrideOffset: number?,
	IKTolerance: number?,
	TouchGround: boolean?,
}

type LegsTable = { [any]: LegData }

local ProceduralAnimatorClass = {}
ProceduralAnimatorClass.__index = ProceduralAnimatorClass

--// Aliases
local CFrameNew = CFrame.new
local CFrameAngles = CFrame.Angles

local Vec3: (number, number, number) -> Vector = vector.create
local VecZero: () -> Vector = vector.zero
local Dot: (Vector, Vector) -> number = vector.dot
local Cross: (Vector, Vector) -> Vector = vector.cross
local Magnitude: (Vector) -> number = vector.magnitude
local Normalize: (Vector) -> Vector = vector.normalize

local Cos = math.cos
local Rad = math.rad
local Min = math.min

--// Constants
local XZ_MASK: Vector = Vec3(1, 0, 1)
local DOWN: Vector = Vec3(0, -10, 0)
local TAU: number = 2 * math.pi

local Signal = require(game:GetService("ReplicatedStorage").ModuleScript)

function ProceduralAnimatorClass.new(
	RootPart: BasePart,
	Legs: LegsTable,
	RootMotor: Motor6D?,
	RaycastParams: RaycastParams
)
	local Self = setmetatable({}, ProceduralAnimatorClass)

	Self.RootPart = RootPart
	Self.RaycastParams = RaycastParams

	if RootMotor then
		Self.RootMotor = RootMotor
		Self.RootMotorC1Store = RootMotor.C1
		Self.WaistCycle = 0
	end

	Self.Legs = Legs

	Self.DefaultStride = 2
	Self.CycleSpeed = 15
	Self.DefaultStrideOffset = 0
	Self.DefaultStrideCF = CFrameNew(0, 0, -Self.DefaultStride / 2)

	Self.MovementDirectionXZ = Vec3(1, 0, 1)
	Self.RootVelocityMagnitude = 0

	Self.FootStep = Signal.new()
	Self.MaxSpeed = 20
	Self.EngineSound = nil
	Self.FootStepSound = nil
	Self.RandomNumGenerator = Random.new()

	Self.WalkBounce = 0.4
	Self.SwayX = -5

	return Self
end

function ProceduralAnimatorClass:MoveLegs(StepCycle: number, Dt: number)
	local RootVelocityMagnitude = self.RootVelocityMagnitude

	for _, Leg: LegData in self.Legs do
		local HipPos: Vector = Leg.HipAttachment.WorldPosition
		local StrideCF = Leg.StrideCF or self.DefaultStrideCF
		local StrideOffset = Leg.StrideOffset or self.DefaultStrideOffset
		local IKTolerance = Leg.IKTolerance or 0

		local DesiredPos: Vector
		local Offset: Vector
		local RaycastResult: RaycastResult?

		if RootVelocityMagnitude > 0.1 then
			Leg.CurrentCycle = (Leg.CurrentCycle + StepCycle) % 360

			local Ground = Leg.FootAttachment.WorldPosition
			local LookCF = CFrameNew(Ground, Ground + self.MovementDirectionXZ)

			DesiredPos = (LookCF * CFrameAngles(-Leg.CurrentCycle, 0, 0) * StrideCF).Position
		else
			DesiredPos = Leg.FootAttachment.WorldPosition + DOWN
		end

		Offset = DesiredPos - HipPos

		local Dir = Normalize(Offset)
		local Dist = Magnitude(Offset) + StrideOffset

		RaycastResult = workspace:Raycast(HipPos, Dir * Dist, self.RaycastParams)

		local FootPos: Vector = RaycastResult and RaycastResult.Position or (HipPos + Dir * Dist)

		if RootVelocityMagnitude > 0.1 then
			Leg.CCDIKController:CCDIKIterateUntil(FootPos, IKTolerance)
		else
			Leg.CCDIKController:CCDIKIterateOnce(FootPos, IKTolerance)
		end

		if not Leg.TouchGround and RaycastResult then
			self.FootStep:Fire(RaycastResult)
		end

		Leg.TouchGround = RaycastResult ~= nil
	end
end

function ProceduralAnimatorClass:MoveTorso(StepCycle: number, Dt10: number, RootVelocity: Vector)
	local RootPart = self.RootPart
	local WaistJoint = self.RootMotor
	local WaistBase = self.RootMotorC1Store

	if not WaistJoint then
		return
	end

	if self.RootVelocityMagnitude > 0.1 then
		self.WaistCycle = (self.WaistCycle + StepCycle) % 360

		local RelV = RootPart.CFrame:VectorToObjectSpace(RootVelocity)
		local RelScaled = RelV * 0.2

		local Bounce = CFrameNew(0, self.WalkBounce * Cos((self.WaistCycle + 135) * 2), 0)

		local SwayZ = Rad(-RelScaled.X) + 0.08 * Cos(self.WaistCycle + 90)
		local SwayY = 0.1 * Cos(self.WaistCycle) - 2 * Rad(RelScaled.X)
		local SwayX = Rad(RelScaled.Z) * 0.5 * self.SwayX

		local Goal = Bounce * WaistBase * CFrameAngles(SwayX, SwayY, SwayZ):Inverse()

		WaistJoint.C1 = WaistJoint.C1:Lerp(Goal, Dt10)
	else
		WaistJoint.C1 = WaistJoint.C1:Lerp(WaistBase, Dt10)
	end
end

function ProceduralAnimatorClass:Animate(Dt: number)
	local Dt10 = Min(Dt * 10, 1)

	local RootPart = self.RootPart
	local Velocity: Vector = RootPart.Velocity

	local RootVelocity: Vector = Vec3(Velocity.X, 0, Velocity.Z)
	local Speed = Magnitude(RootVelocity)

	self.RootVelocityMagnitude = Speed

	if self.EngineSound then
		self.EngineSound.PlaybackSpeed = (Speed / self.MaxSpeed) + 0.6
	end

	if Speed > 0.1 then
		local Dir = Normalize(RootVelocity)
		self.MovementDirectionXZ = self.MovementDirectionXZ + (Dir - self.MovementDirectionXZ) * Dt10
	end

	local StepCycle = (Speed / 16) * Dt * self.CycleSpeed

	self:MoveLegs(StepCycle, Dt)

	if self.RootMotor then
		self:MoveTorso(StepCycle, Dt10, RootVelocity)
	end
end

function ProceduralAnimatorClass:ConnectFootStepSound(Sound: Sound)
	self.FootStep:Connect(function(RaycastResult: RaycastResult)
		local Attachment = Instance.new("Attachment")
		Attachment.WorldPosition = RaycastResult.Position
		Attachment.Parent = workspace.Terrain

		local Footstep = Sound:Clone()
		Footstep.PlaybackSpeed = self.RandomNumGenerator:NextNumber(0.85, 1)
		Footstep.PlayOnRemove = true
		Footstep.Parent = Attachment

		Attachment:Destroy()
	end)
end

function ProceduralAnimatorClass:StartEngineSound(Sound: Sound)
	local Engine = Sound:Clone()
	Engine.Parent = self.RootPart
	Engine.Looped = true
	Engine:Play()

	self.EngineSound = Engine
end

function ProceduralAnimatorClass:InitDragDebug()
	for _, Leg in self.Legs do
		Leg.CCDIKController:InitDragDebug()
	end
end

function ProceduralAnimatorClass:Destroy()
	if self.FootStep then
		self.FootStep:Destroy()
	end

	self = nil
end

return ProceduralAnimatorClass
