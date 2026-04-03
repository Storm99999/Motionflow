--// Motionflow 1
--// Copyright (c) 2026 Celeste Softworks
--// https://github.com/Storm99999/Motionflow

--!native
--!optimize 2

type MotorPair = { Motor6D }
type CreatedList = { Instance }

type CCDIKControllerType = {
	UseLastMotor: boolean,
	GetConstraints: (self: CCDIKControllerType) -> (),
	GetConstraintsFromMotor: (self: CCDIKControllerType, Motor: Instance, Name: string) -> (),
	SetupFoot: (self: CCDIKControllerType, AttachmentNames: { string }, RaycastParams: RaycastParams) -> (),
	PlayJumpAnticipation: ((self: CCDIKControllerType, Options: any?) -> ())?,
	RestoreLegs: ((self: CCDIKControllerType, Options: any?) -> ())?,
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

type FootState = {
	SideOffset: number,
	TargetPart: Part,
	Foot: BasePart,
	IK: IKControl,
	Weight: number,
	IsPlanted: boolean,
	PlantedCFrame: CFrame?,
	LastGroundNormal: Vector3,
}

type WeldMap = {
	Neck: Motor6D?,
	LS: Motor6D?,
	RS: Motor6D?,
	Waist: Motor6D?,
	Root: Motor6D?,
}

type CFrameCache = {
	[string]: { C0: CFrame, C1: CFrame },
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
local TweenService: TweenService = Services.TweenService :: TweenService

--// Self
local Motionflow: Folder = ReplicatedStorage:WaitForChild("Motionflow") :: Folder
local AnimationConfig: any = require(Motionflow:WaitForChild("AnimationConfig"))
local MFRigType: string = string.upper(tostring(AnimationConfig.MFRigType or "AUTO"))
local MFFootlockEnabled: boolean = AnimationConfig.MFFootlocking

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

local function SafeUnit(V: Vector3, Fallback: Vector3): Vector3
	local M: number = V.Magnitude

	if M < 1e-5 then
		return Fallback
	end

	return V / M
end

local function LerpNumber(Current: number, Target: number, Alpha: number): number
	return Current + (Target - Current) * math.clamp(Alpha, 0, 1)
end

local function ProjectOnPlane(V: Vector3, PlaneNormal: Vector3): Vector3
	return V - PlaneNormal * V:Dot(PlaneNormal)
end

local function MakePositionOnlyCFrame(Position: Vector3, ReferenceForward: Vector3): CFrame
	local Up: Vector3 = Vector3.yAxis
	local ForwardFlat: Vector3 = ProjectOnPlane(ReferenceForward, Up)

	ForwardFlat = SafeUnit(ForwardFlat, Vector3.zAxis)

	local Right: Vector3 = SafeUnit(Up:Cross(ForwardFlat), Vector3.xAxis)
	local Forward: Vector3 = SafeUnit(Right:Cross(Up), ForwardFlat)

	return CFrame.fromMatrix(Position, Right, Up, -Forward)
end

local function MakeFootCFrame(HitPosition: Vector3, HitNormal: Vector3, RootLook: Vector3, FootSizeY: number): CFrame
	local Up: Vector3 = SafeUnit(HitNormal, Vector3.yAxis)
	local FlatForward: Vector3 = ProjectOnPlane(RootLook, Up)

	FlatForward = SafeUnit(FlatForward, Vector3.zAxis)

	local Right: Vector3 = SafeUnit(Up:Cross(FlatForward), Vector3.xAxis)
	local Forward: Vector3 = SafeUnit(Right:Cross(Up), RootLook)

	local Position: Vector3 = HitPosition + Up * (FootSizeY * 0.5 + 0.02)

	return CFrame.fromMatrix(Position, Right, Up, -Forward)
end

local function MakeFallbackCFrame(Origin: Vector3, RootLook: Vector3): CFrame
	local Forward: Vector3 = SafeUnit(Vector3.new(RootLook.X, 0, RootLook.Z), Vector3.zAxis)
	local Up: Vector3 = Vector3.yAxis
	local Right: Vector3 = SafeUnit(Up:Cross(Forward), Vector3.xAxis)
	local AlignedForward: Vector3 = SafeUnit(Right:Cross(Up), Forward)

	return CFrame.fromMatrix(Origin, Right, Up, -AlignedForward)
end

local function CreateInvisiblePart(Parent: Instance): Part
	local PartInstance: Part = Instance.new("Part")
	PartInstance.Transparency = 1
	PartInstance.Size = Vector3.new(0.1, 0.1, 0.1)
	PartInstance.CanCollide = false
	PartInstance.CanQuery = false
	PartInstance.CanTouch = false
	PartInstance.Anchored = false
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

local function FindMotor(Character: Model, Names: { string }): Motor6D?
	for _, Name in Names do
		local Obj: Instance? = Character:FindFirstChild(Name, true)

		if Obj and Obj:IsA("Motor6D") then
			return Obj
		end
	end

	return nil
end

local function ResolveRigMode(Character: Model, Humanoid: Humanoid?): string
	if MFRigType == "R6" or MFRigType == "R15" then
		return MFRigType
	end

	if Humanoid and Humanoid.RigType == Enum.HumanoidRigType.R15 then
		return "R15"
	end

	if
		Character:FindFirstChild("UpperTorso")
		and Character:FindFirstChild("RightUpperLeg")
		and Character:FindFirstChild("LeftUpperLeg")
	then
		return "R15"
	end

	return "R6"
end

local function AddFootLocking(Character: Model): (() -> ())?
	local RunService: RunService = game:GetService("RunService")

	local RenderConn: RBXScriptConnection? = nil
	local OriginalCFrames: CFrameCache = {}

	local function GetMotor(Char: Model, PartName: string, MotorName: string): Motor6D?
		local Part: Instance? = Char:FindFirstChild(PartName)
		if not Part then
			return nil
		end
		local Motor: Instance? = Part:FindFirstChild(MotorName)
		if Motor and Motor:IsA("Motor6D") then
			return Motor
		end
		return nil
	end

	local function CacheOriginalCFrames(Welds: WeldMap)
		OriginalCFrames = {}
		for Name, Motor in pairs(Welds) do
			if Motor then
				OriginalCFrames[Name] = {
					C0 = Motor.C0,
					C1 = Motor.C1,
				}
			end
		end
	end

	local function RestoreOriginalCFrames(Welds: WeldMap)
		for Name, Motor in pairs(Welds) do
			if Motor and OriginalCFrames[Name] then
				Motor.C0 = OriginalCFrames[Name].C0
				Motor.C1 = OriginalCFrames[Name].C1
			end
		end
	end

	local function FootlockLoop(Char: Model, Welds: WeldMap)
		local HumanoidRootPart: BasePart? = Char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local Humanoid: Humanoid? = Char:FindFirstChildOfClass("Humanoid")
		if not HumanoidRootPart or not Humanoid then
			return
		end

		local LastHRPCFrame: CFrame = HumanoidRootPart.CFrame
		local FinalDir: number = 0
		local Snap: boolean = false

		local Snappyness: number = 0.18
		local MaxDiffBeforeSnap: number = 1.2

		CacheOriginalCFrames(Welds)

		RenderConn = RunService.RenderStepped:Connect(function(Dt: number)
			if not HumanoidRootPart or not HumanoidRootPart.Parent then
				return
			end

			local CurrentHRPCFrame: CFrame = HumanoidRootPart.CFrame

			local DiffCFrame: CFrame = CurrentHRPCFrame:ToObjectSpace(LastHRPCFrame)
			local _, X, _ = DiffCFrame:ToEulerAnglesYXZ()

			FinalDir += -X

			local DtVal: number = 1 + (Snappyness * Dt * 60)
			local DtValWalk: number = 1 + ((Snappyness * 0.8) * Dt * 60)

			if HumanoidRootPart.AssemblyLinearVelocity.Magnitude > 0.1 then
				FinalDir = math.clamp(FinalDir / DtValWalk, -2.4, 2.4)
			else
				if Snap then
					if math.abs(FinalDir) > 0.1 then
						FinalDir = math.clamp(FinalDir / DtVal, -1, 1)
					else
						Snap = false
					end
				end

				if math.abs(FinalDir) > MaxDiffBeforeSnap then
					if MaxDiffBeforeSnap < 2 then
						Snap = true
						FinalDir = math.clamp(FinalDir / DtVal, -1, 1)
					end
				end
			end

			if Welds.Neck and OriginalCFrames.Neck then
				Welds.Neck.C0 = OriginalCFrames.Neck.C0 * CFrame.fromEulerAnglesYXZ(0, FinalDir * 0.25, 0)
			end

			if Welds.Waist and OriginalCFrames.Waist then
				Welds.Waist.C0 = OriginalCFrames.Waist.C0 * CFrame.fromEulerAnglesYXZ(0, FinalDir * 0.75, 0)
			end

			if Welds.Root and OriginalCFrames.Root then
				Welds.Root.C0 = OriginalCFrames.Root.C0 * CFrame.fromEulerAnglesYXZ(0, -FinalDir, 0)
			end

			LastHRPCFrame = CurrentHRPCFrame
		end)
	end

	local Welds: WeldMap = {
		Neck = GetMotor(Character, "Head", "Neck"),
		LS = GetMotor(Character, "LeftUpperArm", "LeftShoulder"),
		RS = GetMotor(Character, "RightUpperArm", "RightShoulder"),
		Waist = GetMotor(Character, "UpperTorso", "Waist"),
		Root = GetMotor(Character, "LowerTorso", "Root"),
	}

	FootlockLoop(Character, Welds)

	local function Cleanup()
		if RenderConn then
			RenderConn:Disconnect()
			RenderConn = nil
		end
		RestoreOriginalCFrames(Welds)
	end

	Character.AncestryChanged:Connect(function(_, Parent: Instance?)
		if not Parent then
			Cleanup()
		end
	end)

	return Cleanup
end

local function AddFootPlanting(Character: Model): (() -> ())?
	local Created: { Instance } = {}
	local Connections: { RBXScriptConnection } = {}

	local function Track<T>(Object: T): T
		if typeof(Object) == "Instance" then
			table.insert(Created, Object :: any)
		end

		return Object
	end

	local function Connect(Conn: RBXScriptConnection)
		table.insert(Connections, Conn)
	end

	local Humanoid: Humanoid? = Character:FindFirstChildOfClass("Humanoid")
	local RootPart: BasePart = Character:WaitForChild("HumanoidRootPart") :: BasePart

	local LeftUpperLeg: BasePart = Character:WaitForChild("LeftUpperLeg") :: BasePart
	local LeftLowerLeg: BasePart = Character:WaitForChild("LeftLowerLeg") :: BasePart
	local LeftFoot: BasePart = Character:WaitForChild("LeftFoot") :: BasePart

	local RightUpperLeg: BasePart = Character:WaitForChild("RightUpperLeg") :: BasePart
	local RightLowerLeg: BasePart = Character:WaitForChild("RightLowerLeg") :: BasePart
	local RightFoot: BasePart = Character:WaitForChild("RightFoot") :: BasePart

	local TargetsFolder: Folder = Instance.new("Folder")
	TargetsFolder.Name = "Motionflow_FootTargets"
	TargetsFolder.Parent = Character

	Track(TargetsFolder)

	local IKFolder: Folder = Instance.new("Folder")
	IKFolder.Name = "Motionflow_IKControls"
	IKFolder.Parent = Character

	Track(IKFolder)

	local function CreateTarget(Name: string, Foot: BasePart): Part
		local Target: Part = Instance.new("Part")
		Target.Name = Name
		Target.Anchored = true
		Target.CanCollide = false
		Target.CanQuery = false
		Target.CanTouch = false
		Target.Transparency = 1
		Target.Size = Vector3.new(
			math.max(0.12, Foot.Size.X * 0.2),
			math.max(0.12, Foot.Size.Y * 0.2),
			math.max(0.12, Foot.Size.Z * 0.2)
		)
		Target.Parent = TargetsFolder

		return Track(Target)
	end

	local LeftTarget: Part = CreateTarget("LeftTarget", LeftFoot)
	local RightTarget: Part = CreateTarget("RightTarget", RightFoot)

	local function CreatePole(Name: string, SideX: number): Attachment
		local Pole: Attachment = Instance.new("Attachment")
		Pole.Name = Name
		Pole.Position = Vector3.new(SideX * 0.65, -1.35, -1.35)
		Pole.Parent = RootPart

		return Track(Pole)
	end

	local LeftPole: Attachment = CreatePole("LeftPole", -1)
	local RightPole: Attachment = CreatePole("RightPole", 1)

	local function CreateIK(ChainRoot: BasePart, EndEffector: BasePart, Target: BasePart, Pole: Attachment): IKControl
		local Control: IKControl = Instance.new("IKControl")
		Control.Type = Enum.IKControlType.Position
		Control.ChainRoot = ChainRoot
		Control.EndEffector = EndEffector
		Control.Target = Target
		Control.Pole = Pole
		Control.Priority = 999
		Control.Weight = 0
		Control.SmoothTime = 0.08
		Control.Enabled = true
		Control.Parent = IKFolder
		return Track(Control)
	end

	local LeftIK: IKControl = CreateIK(LeftUpperLeg, LeftFoot, LeftTarget, LeftPole)
	local RightIK: IKControl = CreateIK(RightUpperLeg, RightFoot, RightTarget, RightPole)

	local RayParams: RaycastParams = RaycastParams.new()
	RayParams.FilterType = Enum.RaycastFilterType.Exclude
	RayParams.FilterDescendantsInstances = { Character }
	RayParams.IgnoreWater = true

	local LeftState: FootState = {
		SideOffset = -0.55,
		TargetPart = LeftTarget,
		Foot = LeftFoot,
		IK = LeftIK,
		Weight = 0,
		IsPlanted = false,
		PlantedCFrame = nil,
		LastGroundNormal = Vector3.yAxis,
	}

	local RightState: FootState = {
		SideOffset = 0.55,
		TargetPart = RightTarget,
		Foot = RightFoot,
		IK = RightIK,
		Weight = 0,
		IsPlanted = false,
		PlantedCFrame = nil,
		LastGroundNormal = Vector3.yAxis,
	}

	local function UpdateFoot(State: FootState, Dt: number): ()
		local RootCF: CFrame = RootPart.CFrame
		local Velocity: Vector3 = RootPart.AssemblyLinearVelocity
		local HorizontalSpeed: number = Vector3.new(Velocity.X, 0, Velocity.Z).Magnitude
		local MoveDirMag: number = if Humanoid then Humanoid.MoveDirection.Magnitude else 0
		local IsAirborne: boolean = if Humanoid then Humanoid.FloorMaterial == Enum.Material.Air else false
		local IsMoving: boolean = MoveDirMag > 0.12 or HorizontalSpeed > 1.5
		local StandingStill: boolean = (not IsMoving) and not IsAirborne

		local Origin: Vector3 = RootPart.Position
			+ RootCF.RightVector * State.SideOffset
			+ RootCF.LookVector * 0.15
			+ Vector3.new(0, 1.5, 0)
		local Result: RaycastResult? = workspace:Raycast(Origin, Vector3.new(0, -6.0, 0), RayParams)

		local Grounded: boolean = false
		local DesiredCFrame: CFrame

		if Result then
			Grounded = true
			State.LastGroundNormal = Result.Normal
			DesiredCFrame = MakeFootCFrame(Result.Position, Result.Normal, RootCF.LookVector, State.Foot.Size.Y)
		else
			DesiredCFrame = MakeFallbackCFrame(Origin + Vector3.new(0, -4.0, 0), RootCF.LookVector)
		end

		-- Plant only when the character is effectively stationary.
		if StandingStill and Grounded then
			if not State.IsPlanted or State.PlantedCFrame == nil then
				State.PlantedCFrame = DesiredCFrame
				State.IsPlanted = true
			else
				local CurrentPos: Vector3 = State.PlantedCFrame.Position
				local NewPos: Vector3 = DesiredCFrame.Position
				if (NewPos - CurrentPos).Magnitude > 0.18 then
					State.PlantedCFrame = DesiredCFrame
				end
			end
		else
			State.IsPlanted = false
		end

		local TargetPos: Vector3
		local TargetCF: CFrame

		if State.IsPlanted and State.PlantedCFrame ~= nil then
			TargetCF = State.PlantedCFrame
			TargetPos = TargetCF.Position
		else
			TargetCF = DesiredCFrame
			TargetPos = TargetCF.Position
		end

		State.TargetPart.CFrame = MakePositionOnlyCFrame(TargetPos, RootCF.LookVector)

		local DesiredWeight: number = 0
		if StandingStill then
			DesiredWeight = if Grounded then 1 else 0.2
		elseif IsMoving and Grounded then
			DesiredWeight = 0.12
		else
			DesiredWeight = 0
		end

		State.Weight = LerpNumber(State.Weight, DesiredWeight, Dt * 12)
		State.IK.Weight = State.Weight
	end

	Connect(RunService.Heartbeat:Connect(function(Dt: number)
		if not Character.Parent then
			return
		end

		UpdateFoot(LeftState, Dt)
		UpdateFoot(RightState, Dt)
	end))

	local function Cleanup(): ()
		for _, Conn in Connections do
			pcall(function()
				Conn:Disconnect()
			end)
		end

		for _, Obj in Created do
			SafeDestroy(Obj)
		end

		table.clear(Connections)
		table.clear(Created)
	end

	if Humanoid then
		Connect(Humanoid.Died:Connect(Cleanup))
	end

	Connect(Character.AncestryChanged:Connect(function(_, Parent: Instance?)
		if Parent == nil then
			Cleanup()
		end
	end))

	return Cleanup
end

local function AddInverseKinematics(Character: Model): (() -> ())?
	if not Character then
		return nil
	end

	local Humanoid: Humanoid? = Character:FindFirstChildOfClass("Humanoid")
	local RigMode: string = ResolveRigMode(Character, Humanoid)

	if RigMode == "R15" then
		do
			if MFFootlockEnabled then
				AddFootLocking(Character)
			end
		end

		return AddFootPlanting(Character)
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
	RayParams.FilterType = Enum.RaycastFilterType.Exclude
	RayParams.FilterDescendantsInstances = { Character }

	local RootPart: BasePart = Character:WaitForChild("HumanoidRootPart") :: BasePart
	local RootJoint: Motor6D = RootPart:WaitForChild("RootJoint") :: Motor6D

	Animator = ProceduralAnimator.new(RootPart, Legs, RootJoint, RayParams) :: ProceduralAnimatorType

	local RunSound: Sound? = RootPart:FindFirstChild("Running") :: Sound?

	if RunSound ~= nil then
		RunSound.Volume = 0
	end

	local FootstepValue: ObjectValue? = Motionflow.Dependencies.Sounds:FindFirstChild("FootStepSound") :: ObjectValue?

	if FootstepValue ~= nil and FootstepValue.SoundId ~= nil and Animator.ConnectFootStepSound ~= nil then
		Animator:ConnectFootStepSound(FootstepValue)
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

	if Humanoid ~= nil then
		Humanoid.Died:Connect(function(): ()
			Cleanup()
		end)

		Humanoid.StateChanged:Connect(function(_, State: Enum.HumanoidStateType): ()
			if State == Enum.HumanoidStateType.Jumping then
				LeftController:PlayJumpAnticipation()
				RightController:PlayJumpAnticipation()
			elseif State == Enum.HumanoidStateType.Landed then
				LeftController:RestoreLegs()
				RightController:RestoreLegs()
			end
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

local function GivePlayerIK(PlayerInstance: Player): ()
	local OtherCleanup: (() -> ())?

	PlayerInstance.CharacterAdded:Connect(function(Char: Model): ()
		if OtherCleanup then
			pcall(OtherCleanup)
		end

		_, OtherCleanup = AddInverseKinematics(Char)
	end)

	if PlayerInstance.Character then
		_, OtherCleanup = AddInverseKinematics(PlayerInstance.Character)
	end
end

Players.PlayerAdded:Connect(GivePlayerIK)

for _, Pl in Players:GetPlayers() do
	GivePlayerIK(Pl)
end
