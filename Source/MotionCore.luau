--// Motionflow 1
--// Copyright (c) 2026 Celeste Softworks
--// https://github.com/Storm99999/Motionflow

type MotorPair = { Motor6D }
type CreatedList = { Instance }
type CCDIKControllerType = {
	UseLastMotor: boolean,
	GetConstraints: (self: CCDIKControllerType) -> (),
	GetConstraintsFromMotor: (self: CCDIKControllerType, Motor: Instance, Name: string) -> (),
}

type ProceduralAnimatorType = {
	Animate: (self: ProceduralAnimatorType, Dt: number) -> (),
	Destroy: (self: ProceduralAnimatorType) -> (),
	ConnectFootStepSound: ((self: ProceduralAnimatorType, Sound: Instance) -> ())?,
}

type LegConfig = {
	CurrentCycle: number,
	CCDIKController: CCDIKControllerType,
	HipAttachment: Attachment,
	FootAttachment: Attachment,
}

local Services: { [string]: Instance } = setmetatable({}, {
	__index = function(self, Key): Instance
		return game.GetService(game, Key) :: Instance
	end,
}) :: { [string]: Instance }

--// Services
local Players: Players = Services.Players :: Players
local RunService: RunService = Services.RunService :: RunService
local ReplicatedStorage: ReplicatedStorage = Services.ReplicatedStorage :: ReplicatedStorage

--// Self
local Motionflow: Folder = ReplicatedStorage:WaitForChild("Motionflow") :: Folder

--// Dependencies
local Signal

do
	local EnsureDependencies = (function()
		local OK, ERR = pcall(function()
			Signal = require(Motionflow.Dependencies:FindFirstChild("Signal"))
		end)

		if ERR then
			warn("[Motionflow @ MotionCore] Dependency is missing; Please reinstall the module.")
		end
	end)()
end

--// Modules
local CCDIKController: CCDIKControllerType = require(Motionflow.Source.CCDIKController) :: CCDIKControllerType

local ProceduralAnimator: ProceduralAnimatorType =
	require(Motionflow.Source.ProceduralAnimator) :: ProceduralAnimatorType

--// Functions
local function SafeDestroy(Obj: Instance?): ()
	if Obj and Obj.Parent then
		pcall(function(): ()
			Obj:Destroy()
		end)
	end
end

local function CreateInvisiblePart(Parent: Instance): Part
	local PartInstance: Part = Instance.new("Part")
	PartInstance.Transparency = 1
	PartInstance.Size = Vector3.new(0.1, 0.1, 0.1)
	PartInstance.CanCollide = false
	PartInstance.CanQuery = false
	PartInstance.CanTouch = false
	PartInstance.Parent = Parent

	return PartInstance
end

local function CreateMotor(
	Name: string,
	C0: CFrame,
	C1: CFrame,
	Part0: BasePart,
	Part1: BasePart,
	Parent: Instance
): Motor6D
	local Motor: Motor6D = Instance.new("Motor6D")
	Motor.Name = Name
	Motor.C0 = C0
	Motor.C1 = C1
	Motor.Part0 = Part0
	Motor.Part1 = Part1
	Motor.Parent = Parent

	return Motor
end

local function CreateFakeLegs(
	Character: Model,
	Torso: BasePart,
	RealLeftLeg: BasePart,
	RealRightLeg: BasePart
): (MotorPair, MotorPair, Part, Part, CreatedList)
	local Created: CreatedList = {}

	local FakeUpperLLeg = CreateInvisiblePart(Character)
	table.insert(Created, FakeUpperLLeg)

	local LeftHip =
		CreateMotor("Fake Left Hip", CFrame.new(-0.5, -0.95, 0), CFrame.new(0, 0.3, 0), Torso, FakeUpperLLeg, Torso)
	table.insert(Created, LeftHip)

	local LeftLeg =
		CreateMotor("Fake Left Leg", CFrame.new(0, -0.15, 0), CFrame.new(0, 0.6, 0), FakeUpperLLeg, RealLeftLeg, Torso)
	table.insert(Created, LeftLeg)

	local FakeUpperRLeg = CreateInvisiblePart(Character)
	table.insert(Created, FakeUpperRLeg)

	local RightHip =
		CreateMotor("Fake Right Hip", CFrame.new(0.5, -0.95, 0), CFrame.new(0, 0.3, 0), Torso, FakeUpperRLeg, Torso)
	table.insert(Created, RightHip)

	local RightLeg = CreateMotor(
		"Fake Right Leg",
		CFrame.new(0, -0.15, 0),
		CFrame.new(0, 0.6, 0),
		FakeUpperRLeg,
		RealRightLeg,
		Torso
	)

	table.insert(Created, RightLeg)

	return { LeftHip, LeftLeg }, { RightHip, RightLeg }, FakeUpperLLeg, FakeUpperRLeg, Created
end

local function AddInverseKinematics(Character: Model): (() -> ())?
	if not Character then
		return nil
	end

	local CreatedInstances: { Instance } = {}
	local AnimationConnection: RBXScriptConnection? = nil
	local Animator: ProceduralAnimatorType? = nil

	local function Track<T>(Object: T): T
		table.insert(CreatedInstances, Object :: any)

		return Object
	end

	local function CreateAttachment(Parent: Instance, Position: Vector3, Name: string?): Attachment
		local AttachmentInstance: Attachment = Instance.new("Attachment")
		AttachmentInstance.Position = Position

		if Name ~= nil then
			AttachmentInstance.Name = Name
		end

		AttachmentInstance.Parent = Parent

		return Track(AttachmentInstance)
	end

	local function CreateHinge(Part0: BasePart, Part1: BasePart, Pos0: Vector3, Pos1: Vector3): HingeConstraint
		local Attachment0: Attachment = CreateAttachment(Part0, Pos0, nil)
		local Attachment1: Attachment = CreateAttachment(Part1, Pos1, nil)

		local Constraint: HingeConstraint = Instance.new("HingeConstraint")
		Constraint.Attachment0 = Attachment0
		Constraint.Attachment1 = Attachment1
		Constraint.LowerAngle = -145
		Constraint.UpperAngle = -15
		Constraint.Parent = Part0

		return Track(Constraint)
	end

	local function CreateBallSocket(
		Part0: BasePart,
		Part1: BasePart,
		Pos0: Vector3,
		Pos1: Vector3,
		Name: string
	): BallSocketConstraint
		local Attachment0: Attachment = CreateAttachment(Part0, Pos0, nil)
		local Attachment1: Attachment = CreateAttachment(Part1, Pos1, nil)

		local Constraint: BallSocketConstraint = Instance.new("BallSocketConstraint")
		Constraint.Name = Name
		Constraint.LimitsEnabled = true
		Constraint.TwistLimitsEnabled = true
		Constraint.UpperAngle = 5
		Constraint.Attachment0 = Attachment0
		Constraint.Attachment1 = Attachment1
		Constraint.Parent = Part0

		return Track(Constraint)
	end

	local Torso: BasePart = Character:WaitForChild("Torso") :: BasePart
	local RightLeg: BasePart = Character:WaitForChild("Right Leg") :: BasePart
	local LeftLeg: BasePart = Character:WaitForChild("Left Leg") :: BasePart

	local EndEffector: Attachment = CreateAttachment(RightLeg, Vector3.new(0, -0.9, 0), "EndEffector")
	local LeftEndEffector: Attachment = Track(EndEffector:Clone())
	LeftEndEffector.Parent = LeftLeg

	local LeftLegData, RightLegData, FakeUpperLeftLeg, FakeUpperRightLeg, FakeCreated =
		CreateFakeLegs(Character, Torso, LeftLeg, RightLeg)

	for _, Object: Instance in FakeCreated do
		table.insert(CreatedInstances, Object)
	end

	CreateHinge(FakeUpperLeftLeg, LeftLeg, Vector3.new(0, -0.35, 0), Vector3.new(0, 0.4, 0))
	CreateHinge(FakeUpperRightLeg, RightLeg, Vector3.new(0, -0.35, 0), Vector3.new(0, 0.4, 0))

	CreateBallSocket(
		Torso,
		FakeUpperRightLeg,
		Vector3.new(0.5, -0.95, 0),
		Vector3.new(0, 0.3, 0),
		"RightBallSocketConstraint"
	)

	CreateBallSocket(
		Torso,
		FakeUpperLeftLeg,
		Vector3.new(-0.5, -0.95, 0),
		Vector3.new(0, 0.3, 0),
		"LeftBallSocketConstraint"
	)

	local RightHip: Motor6D = Torso:WaitForChild("Right Hip") :: Motor6D
	local LeftHip: Motor6D = Torso:WaitForChild("Left Hip") :: Motor6D

	local PreviousRightHipEnabled: boolean = RightHip.Enabled
	local PreviousLeftHipEnabled: boolean = LeftHip.Enabled

	RightHip.Enabled = false
	LeftHip.Enabled = false

	local RightController: CCDIKControllerType = CCDIKController.new(RightLegData) :: CCDIKControllerType
	RightController.UseLastMotor = true

	RightController:GetConstraints()
	RightController:GetConstraintsFromMotor(RightLegData[1], "RightBallSocketConstraint")

	local LeftController: CCDIKControllerType = CCDIKController.new(LeftLegData) :: CCDIKControllerType
	LeftController.UseLastMotor = true
	LeftController:GetConstraints()
	LeftController:GetConstraintsFromMotor(LeftLegData[1], "LeftBallSocketConstraint")

	local LeftStep: Attachment = CreateAttachment(Torso, Vector3.new(-0.5, -2.8, 0.1), "LeftStepAttach")
	local RightStep: Attachment = CreateAttachment(Torso, Vector3.new(0.5, -2.8, 0.1), "RightStepAttach")

	local RightHipAttachment: Attachment = CreateAttachment(Torso, Vector3.new(0.5, -0.9, 0), "RightHipAttach")
	local LeftHipAttachment: Attachment = CreateAttachment(Torso, Vector3.new(-0.5, -0.9, 0), "LeftHipAttach")

	local Legs: { [string]: LegConfig } = {
		RightLeg = {
			CurrentCycle = 0,
			CCDIKController = RightController,
			HipAttachment = RightHipAttachment,
			FootAttachment = RightStep,
		},

		LeftLeg = {
			CurrentCycle = math.pi,
			CCDIKController = LeftController,
			HipAttachment = LeftHipAttachment,
			FootAttachment = LeftStep,
		},
	}

	local RayParams: RaycastParams = RaycastParams.new()
	RayParams.FilterDescendantsInstances = { Character }

	local RootPart: BasePart = Character:WaitForChild("HumanoidRootPart") :: BasePart
	local RootJoint: Motor6D = RootPart:WaitForChild("RootJoint") :: Motor6D

	Animator = ProceduralAnimator.new(RootPart, Legs, RootJoint, RayParams) :: ProceduralAnimatorType

	local RunSound: Sound? = RootPart:FindFirstChild("Running") :: Sound?

	if RunSound ~= nil then
		RunSound.Volume = 0
	end

	local FootstepValue: ObjectValue? = script:FindFirstChild("FootStepSound") :: ObjectValue?

	if FootstepValue ~= nil and FootstepValue.Value ~= nil and Animator.ConnectFootStepSound ~= nil then
		Animator:ConnectFootStepSound(FootstepValue.Value)
	end

	AnimationConnection = RunService.Heartbeat:Connect(function(Dt: number): ()
		if Animator ~= nil then
			Animator:Animate(Dt * 0.45)
		end
	end)

	local function Cleanup(): ()
		if AnimationConnection ~= nil then
			AnimationConnection:Disconnect()
			AnimationConnection = nil
		end

		if Animator ~= nil then
			pcall(function(): ()
				Animator:Destroy()
			end)
		end

		if Torso.Parent ~= nil then
			local RH: Instance? = Torso:FindFirstChild("Right Hip")
			local LH: Instance? = Torso:FindFirstChild("Left Hip")

			if RH ~= nil then
				(RH :: Motor6D).Enabled = PreviousRightHipEnabled
			end

			if LH ~= nil then
				(LH :: Motor6D).Enabled = PreviousLeftHipEnabled
			end
		end

		for _, Object: Instance in CreatedInstances do
			SafeDestroy(Object)
		end

		table.clear(CreatedInstances)

		SafeDestroy(FakeUpperLeftLeg)
		SafeDestroy(FakeUpperRightLeg)

		Animator = nil
	end

	local Humanoid: Humanoid? = Character:FindFirstChildOfClass("Humanoid")

	if Humanoid ~= nil then
		Humanoid.Died:Connect(function(): ()
			Cleanup()
		end)
	end

	RootPart.AncestryChanged:Connect(function(_, Parent: Instance?): ()
		if Parent == nil then
			Cleanup()
		end
	end)

	Character.AncestryChanged:Connect(function(_, Parent: Instance?): ()
		if Parent == nil then
			Cleanup()
		end
	end)

	return Animator, Cleanup
end
