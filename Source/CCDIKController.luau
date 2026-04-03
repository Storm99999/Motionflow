--// Motionflow 1
--// Copyright (c) 2026 Celeste Softworks
--// https://github.com/Storm99999/Motionflow

--!native
--!optimize 2

type Vector = vector

type Any = { [any]: any }
type MotorList = { Motor6D }
type JointAttachmentMap = { [Motor6D]: Attachment }
type JointConstraintMap = { [Motor6D]: JointConstraintInfo }
type RaycastResultsArray = { RaycastResult? }
type AttachmentArray = { Attachment? }
type TweenArray = { Tween? }
type ConnectionArray = { RBXScriptConnection? }

type JointConstraintInfo = {
	ConstraintType: string,
	UpperAngle: number?,
	LowerAngle: number?,
	TwistLimitsEnabled: boolean?,
	TwistUpperAngle: number?,
	TwistLowerAngle: number?,
	AxisAttachment: Attachment? | string,
	JointAttachment: Attachment? | string,
}

type JumpPoseOptions = {
	duration: number?,
	recoverDuration: number?,
	holdTime: number?,
	hipLift: Vector?,
	hipRot: Vector?,
	kneeRot: Vector?,
	ankleRot: Vector?,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?,
	recoverEasingStyle: Enum.EasingStyle?,
	recoverEasingDirection: Enum.EasingDirection?,
}

type CCDIKControllerObject = {
	[string]: any,

	Maid: any,
	MotorTable: MotorList,
	Motor6DTable: MotorList,
	Constraints: JointConstraintMap?,
	JointInfo: JointAttachmentMap,
	JointAxisInfo: Any,
	EndEffector: Attachment,
	DebugMode: boolean,
	LerpMode: boolean,
	LerpAlpha: number,
	ConstantLerpSpeed: boolean,
	AngularSpeed: number,
	FootOrientationSystem: boolean,
	FootRaycastParams: RaycastParams,
	RaycastLengthDown: number,
	_RayResultTable: RaycastResultsArray,
	UseLastMotor: boolean,
	OverridePose: boolean,
	_OriginalC0: { [Motor6D]: CFrame },
	_ActiveJumpTweens: TweenArray,
	_Connections: ConnectionArray,
	_JumpToken: number,
	JumpPoseDefaults: JumpPoseOptions,
	FootAttachmentTable: AttachmentArray?,
}

local CCDIKController: CCDIKControllerObject = {} :: any
CCDIKController.__index = CCDIKController

local CFrameNew: (...any) -> CFrame = CFrame.new
local CFrameAngles: (...any) -> CFrame = CFrame.Angles
local CFrameLookAt: (...any) -> CFrame = CFrame.lookAt
local CFrameFromAxisAngle: (...any) -> CFrame = CFrame.fromAxisAngle
local Vec3: (number, number, number) -> Vector = vector.create
local VecEmpty: Vector = vector.zero
local Dot: (Vector, Vector) -> number = vector.dot
local Cross: (Vector, Vector) -> Vector = vector.cross
local VectorMagnitude: (Vector) -> number = vector.magnitude
local VectorNormalize: (Vector) -> Vector = vector.normalize
local VectorAngle: (Vector, Vector, Vector?) -> number = vector.angle

local Sin: (number) -> number = math.sin
local Cos: (number) -> number = math.cos
local Acos: (number) -> number = math.acos
local Pi: number = math.pi
local Rad: (number) -> number = math.rad
local Deg: (number) -> number = math.deg
local Sign: (number) -> number = math.sign

local Clamp: (number, number, number) -> number = function(Value: number, Min: number, Max: number): number
	return (Value < Min and Min) or (Value > Max and Max) or Value
end

local InstanceNew: (string) -> Instance = Instance.new

--// Constants
local DOWNVECTOR: Vector = Vec3(0, -1, 0) :: Vector
local EPSILON: number = 1e-5
local ZERO_VECTOR: Vector = Vec3(0, 0, 0) :: Vector

local Services: { [string]: Instance } = setmetatable({}, {
	__index = function(_, Key: string): Instance
		return game:GetService(Key)
	end,
}) :: { [string]: Instance }

--// Services
local Players: Players = Services.Players :: Players
local RunService: RunService = Services.RunService :: RunService
local ReplicatedStorage: ReplicatedStorage = Services.ReplicatedStorage :: ReplicatedStorage
local TweenService: TweenService = Services.TweenService :: TweenService
local Debris: Debris = Services.Debris :: Debris

--// Self
local Motionflow: Folder = ReplicatedStorage:WaitForChild("Motionflow") :: Folder

--// Dependencies
local Maid: any = nil

do
	local EnsureDependencies = (function()
		local OK, ERR = pcall(function()
			Maid = require(Motionflow.Dependencies:FindFirstChild("Maid"))
		end)

		if ERR then
			warn("[Motionflow @ CCDIKController] Dependency is missing; Please reinstall the module.")
		end
	end)()
end

--// Functions
local function FromToRotation(U: Vector, V: Vector, Axis: Vector): CFrame
	local DotValue: number = Dot(U, V)

	if DotValue > 1 - EPSILON then
		return CFrameNew()
	elseif DotValue < -1 + EPSILON then
		return CFrameFromAxisAngle(Axis, Pi)
	end

	local CrossValue: Vector = Cross(U, V)
	local Angle: number = Acos(Clamp(DotValue, -1, 1))

	return CFrameFromAxisAngle(CrossValue, Angle)
end

local function GetRotationBetween(U: Vector, V: Vector, Axis: Vector): CFrame
	local DotValue: number = Dot(U, V)
	local CrossValue: Vector = Cross(U, V)

	if DotValue < -1 + EPSILON then
		return CFrameFromAxisAngle(Axis, Pi)
	end

	return CFrameNew(0, 0, 0, CrossValue.X, CrossValue.Y, CrossValue.Z, 1 + DotValue)
end

local function RotateVectorAround(V: Vector, Amount: number, Axis: Vector): Vector
	local Rotation: CFrame = CFrameFromAxisAngle(Axis, Amount)
	local Rotated: Vector = Rotation:VectorToWorldSpace(V)
	return Rotated
end

local function TwistSwing(Cf: CFrame, Direction: Vector): (CFrame, CFrame)
	local Axis: Vector
	local Theta: number
	Axis, Theta = Cf:ToAxisAngle()

	local W: number = Cos(Theta / 2)
	local S: number = Sin(Theta / 2)
	local V: Vector = Axis * S
	local Projected: Vector = Dot(V, Direction) * Direction
	local Twist: CFrame = CFrameNew(Cf.X, Cf.Y, Cf.Z, Projected.X, Projected.Y, Projected.Z, W)
	local Swing: CFrame = Twist:Inverse() * Cf
	return Swing, Twist
end

local HipJoint: Motor6D = InstanceNew("Motor6D") :: Motor6D
local KneeJoint: Motor6D = InstanceNew("Motor6D") :: Motor6D

local ConstraintsTemplate: { [Motor6D]: JointConstraintInfo } = {
	[KneeJoint] = {
		ConstraintType = "Hinge",
		UpperAngle = 45,
		LowerAngle = -45,
		AxisAttachment = nil,
		JointAttachment = nil,
	},
	[HipJoint] = {
		ConstraintType = "BallSocketConstraint",
		UpperAngle = 45,
		TwistLimitsEnabled = false,
		TwistUpperAngle = 45,
		TwistLowerAngle = -45,
		AxisAttachment = nil,
		JointAttachment = nil,
	},
}

local function MergeJumpOptions(Base: JumpPoseOptions, Override: JumpPoseOptions?): JumpPoseOptions
	local OverrideOptions: JumpPoseOptions = (Override or {}) :: JumpPoseOptions

	return {
		duration = OverrideOptions.duration or Base.duration,
		recoverDuration = OverrideOptions.recoverDuration or Base.recoverDuration,
		holdTime = OverrideOptions.holdTime or Base.holdTime,
		hipLift = OverrideOptions.hipLift or Base.hipLift,
		hipRot = OverrideOptions.hipRot or Base.hipRot,
		kneeRot = OverrideOptions.kneeRot or Base.kneeRot,
		ankleRot = OverrideOptions.ankleRot or Base.ankleRot,
		easingStyle = OverrideOptions.easingStyle or Base.easingStyle,
		easingDirection = OverrideOptions.easingDirection or Base.easingDirection,
		recoverEasingStyle = OverrideOptions.recoverEasingStyle or Base.recoverEasingStyle,
		recoverEasingDirection = OverrideOptions.recoverEasingDirection or Base.recoverEasingDirection,
	}
end

function CCDIKController.new(MotorTable: MotorList, Constraints: JointConstraintMap?): CCDIKControllerObject
	local self: CCDIKControllerObject = setmetatable({} :: any, CCDIKController) :: CCDIKControllerObject

	self.Maid = Maid.new()
	self.MotorTable = MotorTable
	self.Motor6DTable = MotorTable
	self.Constraints = Constraints
	self.JointInfo, self.JointAxisInfo = self:CreateJoints()

	local LastMotor: Motor6D = MotorTable[#MotorTable]
	local EndEffectorInstance: Instance? = LastMotor.Part1:FindFirstChild("EndEffector")
	self.EndEffector = EndEffectorInstance :: Attachment?

	if not self.EndEffector then
		local EndEffector: Attachment = InstanceNew("Attachment") :: Attachment
		EndEffector.Name = "EndEffector"
		EndEffector.Parent = LastMotor.Part1
		self.EndEffector = EndEffector
		self.Maid:GiveTask(EndEffector)
	end

	self.DebugMode = false
	self.LerpMode = false
	self.LerpAlpha = 0.9

	self.ConstantLerpSpeed = true
	self.AngularSpeed = Rad(90)

	self.FootOrientationSystem = false
	self.FootRaycastParams = RaycastParams.new()
	self.RaycastLengthDown = 50
	self._RayResultTable = table.create(3) :: RaycastResultsArray

	self.UseLastMotor = false
	self.OverridePose = false

	self._OriginalC0 = {}
	self._ActiveJumpTweens = {}
	self._Connections = {}
	self._JumpToken = 0

	self.JumpPoseDefaults = {
		duration = 0.11,
		recoverDuration = 0.16,
		holdTime = 0.03,
		hipLift = Vec3(0, 0.16, 0),
		hipRot = Vec3(Rad(-10), Rad(4), Rad(2)),
		kneeRot = Vec3(Rad(26), 0, 0),
		ankleRot = Vec3(Rad(-8), 0, 0),
		easingStyle = Enum.EasingStyle.Sine,
		easingDirection = Enum.EasingDirection.Out,
		recoverEasingStyle = Enum.EasingStyle.Sine,
		recoverEasingDirection = Enum.EasingDirection.Out,
	}

	return self
end

function CCDIKController:SetJumpPoseDefaults(Options: JumpPoseOptions?)
	if not Options then
		return
	end

	self.JumpPoseDefaults = MergeJumpOptions(self.JumpPoseDefaults, Options)
end

function CCDIKController:CreateJoints(): (JointAttachmentMap, Any)
	return self:SetupJoints()
end

function CCDIKController:SetupJoints(): (JointAttachmentMap, Any)
	local Joints: JointAttachmentMap = {} :: JointAttachmentMap
	local JointAxisInfo: Any = {}
	local MotorTable: MotorList = self.MotorTable
	local Constraints: JointConstraintMap? = self.Constraints

	for Index = 1, #MotorTable do
		local Motor: Motor6D = MotorTable[Index]
		local Part0: BasePart = Motor.Part0 :: BasePart

		local JointPosition: Attachment = InstanceNew("Attachment") :: Attachment
		JointPosition.CFrame = Motor.C0
		JointPosition.Name = "JointPosition"
		JointPosition.Parent = Part0
		Joints[Motor] = JointPosition
		self.Maid:GiveTask(JointPosition)

		if Constraints then
			local MotorConstraints: JointConstraintInfo? = Constraints[Motor]
			if MotorConstraints then
				if not MotorConstraints.AxisAttachment then
					local AxisAttachmentInstance: Instance? = Part0:FindFirstChild(Part0.Name .. "AxisAttachment")
					MotorConstraints.AxisAttachment = AxisAttachmentInstance :: Attachment?
				elseif typeof(MotorConstraints.AxisAttachment) == "string" then
					local AxisAttachmentInstance: Instance? =
						Part0:FindFirstChild((MotorConstraints.AxisAttachment :: string) .. "AxisAttachment")
					MotorConstraints.AxisAttachment = AxisAttachmentInstance :: Attachment?
				end

				if not MotorConstraints.JointAttachment then
					local Part1: BasePart = Motor.Part1 :: BasePart
					local JointAttachmentInstance: Instance? = Part1:FindFirstChild(Part0.Name .. "JointAttachment")
					MotorConstraints.JointAttachment = JointAttachmentInstance :: Attachment?
				elseif typeof(MotorConstraints.JointAttachment) == "string" then
					local Part1: BasePart = Motor.Part1 :: BasePart
					local JointAttachmentInstance: Instance? =
						Part1:FindFirstChild((MotorConstraints.JointAttachment :: string) .. "JointAttachment")
					MotorConstraints.JointAttachment = JointAttachmentInstance :: Attachment?
				end
			end
		end
	end

	return Joints, JointAxisInfo
end

function CCDIKController:GetConstraints()
	local Constraints: JointConstraintMap = self.Constraints or {}
	self.Constraints = Constraints

	local MotorTable: MotorList = self.MotorTable

	for Index = 1, #MotorTable do
		local Motor: Motor6D = MotorTable[Index]
		local MotorPart0: BasePart = Motor.Part0 :: BasePart
		local HingeConstraint: HingeConstraint? = MotorPart0:FindFirstChildWhichIsA("HingeConstraint")
		local BallSocketConstraint: BallSocketConstraint? = MotorPart0:FindFirstChildWhichIsA("BallSocketConstraint")

		if HingeConstraint then
			Constraints[Motor] = {
				ConstraintType = "Hinge",
				UpperAngle = HingeConstraint.UpperAngle,
				LowerAngle = HingeConstraint.LowerAngle,
				AxisAttachment = HingeConstraint.Attachment0,
				JointAttachment = HingeConstraint.Attachment1,
			}
		elseif BallSocketConstraint then
			Constraints[Motor] = {
				ConstraintType = "BallSocketConstraint",
				UpperAngle = BallSocketConstraint.UpperAngle,
				TwistLimitsEnabled = BallSocketConstraint.TwistLimitsEnabled,
				TwistUpperAngle = BallSocketConstraint.TwistUpperAngle,
				TwistLowerAngle = BallSocketConstraint.TwistLowerAngle,
				AxisAttachment = BallSocketConstraint.Attachment0,
				JointAttachment = BallSocketConstraint.Attachment1,
			}
		end
	end
end

function CCDIKController:GetConstraintsFromMotor(Motor: Motor6D, ConstraintName: string)
	local Constraints: JointConstraintMap = self.Constraints or {}
	self.Constraints = Constraints

	local Part0: BasePart = Motor.Part0 :: BasePart
	local Constraint: Instance? = Part0:FindFirstChild(ConstraintName)

	if not Constraint then
		return
	end

	if Constraint:IsA("HingeConstraint") then
		local Hinge: HingeConstraint = Constraint
		Constraints[Motor] = {
			ConstraintType = "Hinge",
			UpperAngle = Hinge.UpperAngle,
			LowerAngle = Hinge.LowerAngle,
			AxisAttachment = Hinge.Attachment0,
			JointAttachment = Hinge.Attachment1,
		}
	elseif Constraint:IsA("BallSocketConstraint") then
		local BallSocket: BallSocketConstraint = Constraint
		Constraints[Motor] = {
			ConstraintType = "BallSocketConstraint",
			UpperAngle = BallSocket.UpperAngle,
			TwistLimitsEnabled = BallSocket.TwistLimitsEnabled,
			TwistUpperAngle = BallSocket.TwistUpperAngle,
			TwistLowerAngle = BallSocket.TwistLowerAngle,
			AxisAttachment = BallSocket.Attachment0,
			JointAttachment = BallSocket.Attachment1,
		}
	end
end

function CCDIKController:_CCDIKIterateFoot(Step: number?)
	if self.OverridePose then
		return
	end

	local Constraints: JointConstraintMap? = self.Constraints
	local MotorTable: MotorList = self.MotorTable
	local FootJoint: Motor6D = MotorTable[#MotorTable]

	FootJoint.C0 *= FootJoint.Transform

	self:OrientFootMotorToFloor(FootJoint, Step)

	FootJoint.Transform = CFrameNew()

	if Constraints then
		local JointConstraintInfo: JointConstraintInfo? = Constraints[FootJoint]

		if JointConstraintInfo then
			if JointConstraintInfo.ConstraintType == "Hinge" then
				self:RotateToHingeAxis(FootJoint, JointConstraintInfo)
			elseif JointConstraintInfo.ConstraintType == "BallSocketConstraint" then
				self:RotateToBallSocketConstraintAxis(FootJoint, JointConstraintInfo)
			end
		end
	end
end

function CCDIKController:_CCDIKIterateStep(GoalPosition: Vector, Step: number?)
	if self.OverridePose then
		return
	end

	local Constraints: JointConstraintMap? = self.Constraints
	local MotorTable: MotorList = self.MotorTable
	local UseLastMotor: number = self.UseLastMotor and 1 or 0

	for Index = #MotorTable - 1 + UseLastMotor, 1, -1 do
		local CurrentJoint: Motor6D = MotorTable[Index]

		CurrentJoint.C0 *= CurrentJoint.Transform
		self:RotateFromEffectorToGoal(CurrentJoint, GoalPosition, Step)
		CurrentJoint.Transform = CFrameNew()

		if Constraints then
			local JointConstraintInfo: JointConstraintInfo? = Constraints[CurrentJoint]

			if JointConstraintInfo then
				if JointConstraintInfo.ConstraintType == "Hinge" then
					self:RotateToHingeAxis(CurrentJoint, JointConstraintInfo)
				elseif JointConstraintInfo.ConstraintType == "BallSocketConstraint" then
					self:RotateToBallSocketConstraintAxis(CurrentJoint, JointConstraintInfo)
				end
			end
		end
	end
end

function CCDIKController:CCDIKIterateOnce(GoalPosition: Vector, Tolerance: number?, Step: number?)
	if self.OverridePose then
		return
	end

	local EndEffectorPosition: Vector = self.EndEffector.WorldPosition
	local DistanceToGoal: Vector = EndEffectorPosition - GoalPosition
	local ToleranceValue: number = Tolerance or 1

	if VectorMagnitude(DistanceToGoal) > ToleranceValue then
		self:_CCDIKIterateStep(GoalPosition, Step)
	end

	if self.FootOrientationSystem then
		self:_CCDIKIterateFoot(Step)
	end
end

function CCDIKController:CCDIKIterateOnceDebug(GoalPosition: Vector, Tolerance: number?, Step: number?)
	self:_CCDIKIterateStep(GoalPosition, Step)
end

function CCDIKController:CCDIKIterateUntil(
	GoalPosition: Vector,
	Tolerance: number?,
	MaxBreakCount: number?,
	Step: number?
)
	if self.OverridePose then
		return
	end

	local MaxIterations: number = MaxBreakCount or 10
	local CurrentIterationCount: number = 0
	local EndEffectorPosition: Vector = self.EndEffector.WorldPosition
	local DistanceToGoal: Vector = EndEffectorPosition - GoalPosition
	local ToleranceValue: number = Tolerance or 1

	while VectorMagnitude(DistanceToGoal) > ToleranceValue and CurrentIterationCount < MaxIterations do
		CurrentIterationCount += 1
		self:_CCDIKIterateStep(GoalPosition, Step)

		if self.FootOrientationSystem then
			self:_CCDIKIterateFoot(Step)
		end

		DistanceToGoal = self.EndEffector.WorldPosition - GoalPosition
	end
end

function CCDIKController:EnableOverridePose(Enable: boolean)
	self.OverridePose = Enable
end

local function WorldCFrameToC0ObjectSpace(Motor6DJoint: Motor6D, WorldCFrame: CFrame): CFrame
	local Part1CF: CFrame = Motor6DJoint.Part1.CFrame
	local C1Store: CFrame = Motor6DJoint.C1
	local C0Store: CFrame = Motor6DJoint.C0
	local RelativeToPart1: CFrame = C0Store * C1Store:Inverse() * Part1CF:Inverse() * WorldCFrame * C1Store

	RelativeToPart1 -= RelativeToPart1.Position

	local GoalC0CFrame: CFrame = RelativeToPart1 + C0Store.Position

	return GoalC0CFrame
end

local function CalculateGoalFromToC0CFrame(Motor6DJoint: Motor6D, U: Vector, V: Vector, Axis: Vector): CFrame
	local RotationCFrame: CFrame = FromToRotation(U, V, Axis)
	local Part1CF: CFrame = Motor6DJoint.Part1.CFrame
	local C1Store: CFrame = Motor6DJoint.C1
	local C0Store: CFrame = Motor6DJoint.C0
	local GoalWorldCFrame: CFrame = RotationCFrame * Part1CF
	local RelativeToPart1: CFrame = C0Store * C1Store:Inverse() * Part1CF:Inverse() * GoalWorldCFrame * C1Store

	RelativeToPart1 -= RelativeToPart1.Position

	local GoalC0CFrame: CFrame = RelativeToPart1 + C0Store.Position

	return GoalC0CFrame
end

function CCDIKController.RotateJointFromTo(Motor6DJoint: Motor6D, U: Vector, V: Vector, Axis: Vector)
	local GoalC0CFrame: CFrame = CalculateGoalFromToC0CFrame(Motor6DJoint, U, V, Axis)
	Motor6DJoint.C0 = GoalC0CFrame
end

local TweenInfoShort: TweenInfo = TweenInfo.new(0.1)
function CCDIKController.RotateJointFromToTween(Motor6DJoint: Motor6D, U: Vector, V: Vector, Axis: Vector)
	local GoalC0CFrame: CFrame = CalculateGoalFromToC0CFrame(Motor6DJoint, U, V, Axis)
	local Tween: Tween = TweenService:Create(Motor6DJoint, TweenInfoShort, { C0 = GoalC0CFrame })

	Tween:Play()
	Tween.Completed:Wait()
end

function CCDIKController:RotateJointFromToWithLerp(
	Motor6DJoint: Motor6D,
	U: Vector,
	V: Vector,
	Axis: Vector,
	Step: number?
)
	local GoalC0CFrame: CFrame = CalculateGoalFromToC0CFrame(Motor6DJoint, U, V, Axis)
	local LerpAlpha: number = self.LerpAlpha
	local CurrentC0: CFrame = Motor6DJoint.C0

	if Step and self.ConstantLerpSpeed then
		local AngularDistance: number = VectorAngle(CurrentC0.LookVector, GoalC0CFrame.LookVector)

		if AngularDistance > EPSILON then
			local EstimatedTime: number = self.AngularSpeed / AngularDistance
			LerpAlpha = math.min(Step * EstimatedTime, 1)
		end
	end

	Motor6DJoint.C0 = CurrentC0:Lerp(GoalC0CFrame, LerpAlpha)
end

function CCDIKController:RotateFromEffectorToGoal(Motor6D: Motor6D, GoalPosition: Vector, Step: number?)
	if self.OverridePose then
		return
	end

	local Part0CF: CFrame = Motor6D.Part0.CFrame
	local JointWorldPosition: Vector = self.JointInfo[Motor6D].WorldPosition
	local EndEffectorPosition: Vector = self.EndEffector.WorldPosition
	local DirectionToEffector: Vector = EndEffectorPosition - JointWorldPosition
	local DirectionToGoal: Vector = GoalPosition - JointWorldPosition

	if VectorMagnitude(DirectionToEffector) <= EPSILON or VectorMagnitude(DirectionToGoal) <= EPSILON then
		return
	end

	DirectionToEffector = VectorNormalize(DirectionToEffector)
	DirectionToGoal = VectorNormalize(DirectionToGoal)

	if self.DebugMode then
		self:VisualizeVector(JointWorldPosition, EndEffectorPosition - JointWorldPosition, BrickColor.Blue())
		self:VisualizeVector(JointWorldPosition, GoalPosition - JointWorldPosition, BrickColor.Red())
		self.RotateJointFromToTween(Motor6D, DirectionToEffector, DirectionToGoal, Part0CF.UpVector)

		return
	end

	if self.LerpMode ~= true then
		self.RotateJointFromTo(Motor6D, DirectionToEffector, DirectionToGoal, Part0CF.RightVector)
	else
		self:RotateJointFromToWithLerp(Motor6D, DirectionToEffector, DirectionToGoal, Part0CF.RightVector, Step)
	end
end

function CCDIKController:RotateToHingeAxis(Motor6D: Motor6D, JointConstraintInfo: JointConstraintInfo)
	local Part0CF: CFrame = Motor6D.Part0.CFrame
	local AxisAttachment: Attachment? = JointConstraintInfo.AxisAttachment :: Attachment?
	local JointAttachment: Attachment? = JointConstraintInfo.JointAttachment :: Attachment?

	if not AxisAttachment or not JointAttachment then
		return
	end

	local HingeAxis: Vector = AxisAttachment.WorldAxis
	local CurrentHingeAxis: Vector = JointAttachment.WorldAxis

	self.RotateJointFromTo(Motor6D, CurrentHingeAxis, HingeAxis, Part0CF.RightVector)

	local AxisCFrame: CFrame = AxisAttachment.WorldCFrame
	local JointCFrame: CFrame = JointAttachment.WorldCFrame

	local UpperAngle: number = JointConstraintInfo.UpperAngle or 180
	local LowerAngle: number = JointConstraintInfo.LowerAngle or -180

	local LocalCFrame: CFrame = AxisCFrame:ToObjectSpace(JointCFrame)
	local X: number
	local Y: number
	local Z: number

	X, Y, Z = LocalCFrame:ToEulerAnglesXYZ()

	local XAngle: number = Deg(X)
	local ConstrainedX: number = Clamp(XAngle, LowerAngle, UpperAngle)
	local ConstrainedJointCFrame: CFrame = CFrameAngles(Rad(ConstrainedX), 0, 0)
	local NewWorldJointCFrame: CFrame = AxisCFrame:ToWorldSpace(ConstrainedJointCFrame)
	local NewPart1CFrame: CFrame = NewWorldJointCFrame * JointAttachment.CFrame:Inverse()
	local GoalCFRotation: CFrame = WorldCFrameToC0ObjectSpace(Motor6D, NewPart1CFrame)

	Motor6D.C0 = GoalCFRotation
end

function CCDIKController:RotateToBallSocketConstraintAxis(Motor6D: Motor6D, JointConstraintInfo: JointConstraintInfo)
	local Part0CF: CFrame = Motor6D.Part0.CFrame
	local AxisAttachment: Attachment? = JointConstraintInfo.AxisAttachment :: Attachment?
	local JointAttachment: Attachment? = JointConstraintInfo.JointAttachment :: Attachment?

	if not AxisAttachment or not JointAttachment then
		return
	end

	local CenterAxis: Vector = AxisAttachment.WorldAxis
	local CurrentCenterAxis: Vector = JointAttachment.WorldAxis
	local AngleDifference: number = VectorAngle(CurrentCenterAxis, CenterAxis)
	local ConstraintUpperAngle: number = Rad(JointConstraintInfo.UpperAngle or 45)

	if AngleDifference > ConstraintUpperAngle then
		local Axis: Vector = Cross(CurrentCenterAxis, CenterAxis)
		local AngleDelta: number = AngleDifference - ConstraintUpperAngle
		local NewCenterAxisWithinBounds: Vector = RotateVectorAround(CurrentCenterAxis, AngleDelta, Axis)

		self.RotateJointFromTo(Motor6D, CurrentCenterAxis, NewCenterAxisWithinBounds, Part0CF.RightVector)
	end

	if JointConstraintInfo.TwistLimitsEnabled then
		local AxisCFrame: CFrame = AxisAttachment.WorldCFrame
		local CurrentJointCFrame: CFrame = JointAttachment.WorldCFrame
		local TwistSwingAxis: Vector = AxisAttachment.WorldAxis

		local JointRelativeCFrame: CFrame = AxisCFrame:ToObjectSpace(CurrentJointCFrame)
		local Swing: CFrame
		local Twist: CFrame

		Swing, Twist = TwistSwing(JointRelativeCFrame, TwistSwingAxis)

		local Axis: Vector
		local Angle: number

		Axis, Angle = Twist:ToAxisAngle()

		local AxisSign: number = Sign(Dot(Axis, TwistSwingAxis))
		Axis = AxisSign * Axis
		Angle = AxisSign * Angle
		Angle = Deg(Angle)

		local UpperAngle: number = JointConstraintInfo.TwistUpperAngle or 0
		local LowerAngle: number = JointConstraintInfo.TwistLowerAngle or 0
		local NotConstrained: boolean = false

		if Angle > UpperAngle then
			Angle = UpperAngle
		elseif Angle < LowerAngle then
			Angle = LowerAngle
		else
			NotConstrained = true
		end

		if not NotConstrained then
			local NewTwist: CFrame = CFrameFromAxisAngle(Axis, Rad(Angle))
			local NewConstrainedRelativeCFrame: CFrame = NewTwist * Swing
			local NewJointWorldCFrame: CFrame = AxisCFrame * NewConstrainedRelativeCFrame
			local Part1CF: CFrame = NewJointWorldCFrame * JointAttachment.CFrame:Inverse()
			local GoalCF: CFrame = WorldCFrameToC0ObjectSpace(Motor6D, Part1CF)

			Motor6D.C0 = GoalCF
		end
	end
end

function CCDIKController:SetupFoot(AttachmentNameTable: { string }, RaycastParams: RaycastParams)
	local MotorTable: MotorList = self.MotorTable
	local FootJoint: Motor6D = MotorTable[#MotorTable]
	local FootPart: BasePart = FootJoint.Part1 :: BasePart
	local FootAttachmentTable: AttachmentArray = table.create(#AttachmentNameTable) :: AttachmentArray

	local HalfX: number = math.max(FootPart.Size.X * 0.35, 0.15)
	local HalfZ: number = math.max(FootPart.Size.Z * 0.35, 0.15)
	local SoleY: number = -(FootPart.Size.Y * 0.5) + 0.02
	local DefaultOffsets: { Vector3 } = {
		Vector3.new(-HalfX, SoleY, HalfZ),
		Vector3.new(HalfX, SoleY, HalfZ),
		Vector3.new(0, SoleY, -HalfZ),
	}

	for Index = 1, #AttachmentNameTable do
		local Name: string = AttachmentNameTable[Index]
		local AttachmentInstance: Instance? = FootPart:FindFirstChild(Name)

		if AttachmentInstance and AttachmentInstance:IsA("Attachment") then
			FootAttachmentTable[Index] = AttachmentInstance :: Attachment
		else
			local NewAttachment: Attachment = InstanceNew("Attachment") :: Attachment
			NewAttachment.Name = Name
			NewAttachment.Position = DefaultOffsets[Index] or Vector3.zero
			NewAttachment.Parent = FootPart
			FootAttachmentTable[Index] = NewAttachment
			self.Maid:GiveTask(NewAttachment)
		end
	end

	self.FootAttachmentTable = FootAttachmentTable
	self.FootRaycastParams = RaycastParams
	self.FootOrientationSystem = true
end

function CCDIKController:OrientFootMotorToFloor(Motor6D: Motor6D, Step: number?)
	local AttachmentTable: AttachmentArray? = self.FootAttachmentTable

	if not AttachmentTable then
		return
	end

	local LengthToFloor: number = self.RaycastLengthDown
	local RayResultTable: RaycastResultsArray = self._RayResultTable
	local RaycastParams: RaycastParams = self.FootRaycastParams

	for Index = 1, 3 do
		local Attachment: Attachment? = AttachmentTable[Index]

		if not Attachment then
			return
		end

		local RayOrigin: Vector = Attachment.WorldPosition
		local RayDown: Vector = -Attachment.WorldCFrame.UpVector * LengthToFloor
		RayResultTable[Index] = workspace:Raycast(RayOrigin, RayDown, RaycastParams)
	end

	local RaycastNilCheck: boolean = (RayResultTable[1] and RayResultTable[2] and RayResultTable[3]) == nil
	local FootCFrame: CFrame = self.EndEffector.WorldCFrame

	local NewUpVector: Vector = if RaycastNilCheck
		then FootCFrame.UpVector
		else VectorNormalize(
			Cross(
				RayResultTable[2].Position - RayResultTable[1].Position,
				RayResultTable[3].Position - RayResultTable[1].Position
			)
		)

	local CurrentFootUpVector: Vector = FootCFrame.UpVector

	if not RaycastNilCheck then
		self:RotateJointFromToWithLerp(Motor6D, CurrentFootUpVector, NewUpVector, FootCFrame.UpVector, Step)
	end

	local Constraints: JointConstraintMap? = self.Constraints

	if Constraints then
		local JointConstraintInfo: JointConstraintInfo? = Constraints[Motor6D]

		if JointConstraintInfo then
			if JointConstraintInfo.ConstraintType == "Hinge" then
				self:RotateToHingeAxis(Motor6D, JointConstraintInfo)
			elseif JointConstraintInfo.ConstraintType == "BallSocketConstraint" then
				self:RotateToBallSocketConstraintAxis(Motor6D, JointConstraintInfo)
			end
		end
	end
end

function CCDIKController:InitDragDebug()
	self.LerpMode = false

	local LastPart1: BasePart = self.MotorTable[#self.MotorTable].Part1 :: BasePart
	local DragMe: Part = InstanceNew("Part") :: Part

	DragMe.CanCollide = false
	DragMe.Anchored = true
	DragMe.Size = Vec3(1, 1, 1)
	DragMe.BrickColor = BrickColor.random()
	DragMe.Position = LastPart1.Position
	DragMe.Name = "DragMe!: " .. LastPart1.Name
	DragMe.Parent = workspace

	local Connection: RBXScriptConnection = RunService.Heartbeat:Connect(function()
		self:CCDIKIterateOnce(DragMe.Position, 0)
	end)

	self._Connections[#self._Connections + 1] = Connection
	self.Maid:GiveTask(Connection)
end

function CCDIKController:InitTweenDragDebug()
	local LastPart1: BasePart = self.MotorTable[#self.MotorTable].Part1 :: BasePart
	self.DebugMode = true

	for Index = 1, #self.MotorTable - 1 do
		local Motor1: Motor6D = self.MotorTable[Index]
		local Motor2: Motor6D = self.MotorTable[Index + 1]

		local T1: Vector = self.JointInfo[Motor1].WorldPosition
		local T2: Vector = self.JointInfo[Motor2].WorldPosition

		local Position: Vector = T1
		local Direction: Vector = T2 - T1
		local DirectionMagnitude: number = VectorMagnitude(Direction)

		local WedgePart: WedgePart = InstanceNew("WedgePart") :: WedgePart
		WedgePart.Size = Vec3(0.1, 0.1, DirectionMagnitude)
		WedgePart.CFrame = CFrameLookAt(Position, Position + Direction) * CFrameNew(0, 0, -DirectionMagnitude / 2)
		WedgePart.CanCollide = false
		WedgePart.Anchored = true
		WedgePart.Parent = workspace
		WedgePart.Name = "I am a limb vector"

		self.Maid:GiveTask(WedgePart)

		local WeldConstraint: WeldConstraint = InstanceNew("WeldConstraint") :: WeldConstraint
		WeldConstraint.Part0 = WedgePart
		WeldConstraint.Part1 = Motor2.Parent :: BasePart
		WeldConstraint.Parent = Motor2.Parent

		self.Maid:GiveTask(WeldConstraint)
	end

	for Index = 1, #self.MotorTable do
		local Motor: Motor6D = self.MotorTable[Index];

		(Motor.Part1 :: BasePart).Transparency = 0.75
		(Motor.Part0 :: BasePart).Transparency = 0.75
	end

	local DragMe: Part = InstanceNew("Part") :: Part
	DragMe.CanCollide = false
	DragMe.Anchored = true
	DragMe.Size = Vec3(1, 1, 1)
	DragMe.BrickColor = BrickColor.random()
	DragMe.Position = LastPart1.Position
	DragMe.Name = "DragMe!: " .. LastPart1.Name
	DragMe.Parent = workspace

	self.Maid:GiveTask(DragMe)

	task.spawn(function()
		while true do
			task.wait()
			self:CCDIKIterateOnceDebug(DragMe.Position)
		end
	end)
end

function CCDIKController:VisualizeVector(Position: Vector, Direction: Vector, BrickColorValue: BrickColor?)
	local DirectionMagnitude: number = VectorMagnitude(Direction)
	local WedgePart: WedgePart = InstanceNew("WedgePart") :: WedgePart
	WedgePart.Size = Vec3(0.1, 0.1, DirectionMagnitude)
	WedgePart.CFrame = CFrameLookAt(Position, Position + Direction) * CFrameNew(0, 0, -DirectionMagnitude / 2)
	WedgePart.Anchored = true
	WedgePart.CanCollide = false
	WedgePart.BrickColor = BrickColorValue or BrickColor.random()
	WedgePart.Parent = workspace

	Debris:AddItem(WedgePart, 0.75)
end

function CCDIKController:_EnsureSavedOriginals(MotorList: { Motor6D })
	local OriginalC0: { [Motor6D]: CFrame } = self._OriginalC0

	for Index = 1, #MotorList do
		local Motor: Motor6D = MotorList[Index]

		if OriginalC0[Motor] == nil then
			OriginalC0[Motor] = Motor.C0
		end
	end
end

function CCDIKController:_CancelActiveTweens()
	local ActiveTweens: TweenArray = self._ActiveJumpTweens

	for Index = 1, #ActiveTweens do
		local TweenObject: Tween? = ActiveTweens[Index]

		if TweenObject then
			pcall(function()
				TweenObject:Cancel()
			end)
		end

		ActiveTweens[Index] = nil
	end
end

function CCDIKController:_BuildJumpPose(Options: JumpPoseOptions?): JumpPoseOptions
	local Pose: JumpPoseOptions = MergeJumpOptions(self.JumpPoseDefaults, Options)

	return {
		duration = Pose.duration or 0.11,
		recoverDuration = Pose.recoverDuration or 0.16,
		holdTime = Pose.holdTime or 0.03,
		hipLift = Pose.hipLift or Vec3(0, 0.16, 0),
		hipRot = Pose.hipRot or Vec3(Rad(-10), Rad(4), Rad(2)),
		kneeRot = Pose.kneeRot or Vec3(Rad(26), 0, 0),
		ankleRot = Pose.ankleRot or Vec3(Rad(-8), 0, 0),
		easingStyle = Pose.easingStyle or Enum.EasingStyle.Sine,
		easingDirection = Pose.easingDirection or Enum.EasingDirection.Out,
		recoverEasingStyle = Pose.recoverEasingStyle or Enum.EasingStyle.Sine,
		recoverEasingDirection = Pose.recoverEasingDirection or Enum.EasingDirection.Out,
	}
end

function CCDIKController:PlayJumpAnticipation(Options: JumpPoseOptions?)
	local Pose: JumpPoseOptions = self:_BuildJumpPose(Options)
	local MotorTable: MotorList = self.MotorTable

	if #MotorTable < 2 then
		return
	end

	local HipMotor: Motor6D = MotorTable[1]
	local KneeMotor: Motor6D = MotorTable[2]
	local AnkleMotor: Motor6D = MotorTable[#MotorTable]

	self:_EnsureSavedOriginals({ HipMotor, KneeMotor, AnkleMotor })
	self:_CancelActiveTweens()

	local OriginalHipC0: CFrame? = self._OriginalC0[HipMotor]
	local OriginalKneeC0: CFrame? = self._OriginalC0[KneeMotor]
	local OriginalAnkleC0: CFrame? = self._OriginalC0[AnkleMotor]

	if not OriginalHipC0 or not OriginalKneeC0 or not OriginalAnkleC0 then
		self.OverridePose = false
		return
	end

	self.OverridePose = true
	self._JumpToken += 1

	local HipLift: Vector = Pose.hipLift or Vec3(0, 0.16, 0)
	local HipRot: Vector = Pose.hipRot or Vec3(Rad(-10), Rad(4), Rad(2))
	local KneeRot: Vector = Pose.kneeRot or Vec3(Rad(26), 0, 0)
	local AnkleRot: Vector = Pose.ankleRot or Vec3(Rad(-8), 0, 0)

	local HipGoal: CFrame = OriginalHipC0 * CFrameNew(HipLift) * CFrameAngles(HipRot.X, HipRot.Y, HipRot.Z)
	local KneeGoal: CFrame = OriginalKneeC0 * CFrameAngles(KneeRot.X, KneeRot.Y, KneeRot.Z)
	local AnkleGoal: CFrame = OriginalAnkleC0 * CFrameAngles(AnkleRot.X, AnkleRot.Y, AnkleRot.Z)

	local TweenInfoLocal: TweenInfo = TweenInfo.new(
		Pose.duration or 0.11,
		Pose.easingStyle or Enum.EasingStyle.Sine,
		Pose.easingDirection or Enum.EasingDirection.Out
	)

	local HipTween: Tween = TweenService:Create(HipMotor, TweenInfoLocal, { C0 = HipGoal })
	local KneeTween: Tween = TweenService:Create(KneeMotor, TweenInfoLocal, { C0 = KneeGoal })
	local AnkleTween: Tween = TweenService:Create(AnkleMotor, TweenInfoLocal, { C0 = AnkleGoal })

	local ActiveTweens: TweenArray = self._ActiveJumpTweens
	ActiveTweens[1] = HipTween
	ActiveTweens[2] = KneeTween
	ActiveTweens[3] = AnkleTween

	HipTween:Play()
	KneeTween:Play()
	AnkleTween:Play()
end

function CCDIKController:RestoreLegs(Options: JumpPoseOptions?)
	local Pose: JumpPoseOptions = self:_BuildJumpPose(Options)
	local MotorTable: MotorList = self.MotorTable

	self:_CancelActiveTweens()

	if #MotorTable < 2 then
		self.OverridePose = false

		return
	end

	local HipMotor: Motor6D = MotorTable[1]
	local KneeMotor: Motor6D = MotorTable[2]
	local AnkleMotor: Motor6D = MotorTable[#MotorTable]

	local OriginalHipC0: CFrame = self._OriginalC0[HipMotor] or HipMotor.C0
	local OriginalKneeC0: CFrame = self._OriginalC0[KneeMotor] or KneeMotor.C0
	local OriginalAnkleC0: CFrame = self._OriginalC0[AnkleMotor] or AnkleMotor.C0

	local JumpToken: number = self._JumpToken
	local TweenInfoLocal: TweenInfo = TweenInfo.new(
		Pose.recoverDuration or 0.16,
		Pose.recoverEasingStyle or Enum.EasingStyle.Sine,
		Pose.recoverEasingDirection or Enum.EasingDirection.Out
	)

	local HipTween: Tween = TweenService:Create(HipMotor, TweenInfoLocal, { C0 = OriginalHipC0 })
	local KneeTween: Tween = TweenService:Create(KneeMotor, TweenInfoLocal, { C0 = OriginalKneeC0 })
	local AnkleTween: Tween = TweenService:Create(AnkleMotor, TweenInfoLocal, { C0 = OriginalAnkleC0 })

	local ActiveTweens: TweenArray = self._ActiveJumpTweens
	ActiveTweens[1] = HipTween
	ActiveTweens[2] = KneeTween
	ActiveTweens[3] = AnkleTween

	HipTween:Play()
	KneeTween:Play()
	AnkleTween:Play()

	task.spawn(function()
		HipTween.Completed:Wait()

		if self and self._JumpToken == JumpToken then
			self.OverridePose = false
		end

		for Index = 1, #ActiveTweens do
			ActiveTweens[Index] = nil
		end
	end)
end

function CCDIKController:Jump(Options: JumpPoseOptions?)
	self:PlayJumpAnticipation(Options)

	local Pose: JumpPoseOptions = self:_BuildJumpPose(Options)

	task.spawn(function()
		task.wait(Pose.holdTime or 0.03)

		if self and self.OverridePose then
			self:RestoreLegs(Options)
		end
	end)
end

function CCDIKController.commandBarSetupJoints(Model: Model)
	local Descendants: { Instance } = Model:GetDescendants()

	for Index = 1, #Descendants do
		local Object: Instance = Descendants[Index]

		if Object:IsA("Motor6D") then
			local Motor: Motor6D = Object
			local Part0: BasePart = Motor.Part0 :: BasePart
			local Part1: BasePart = Motor.Part1 :: BasePart

			local AxisAttachment: Attachment = InstanceNew("Attachment") :: Attachment
			AxisAttachment.CFrame = Motor.C0
			AxisAttachment.Name = Part0.Name .. "AxisAttachment"
			AxisAttachment.Parent = Part0

			local JointAttachment: Attachment = InstanceNew("Attachment") :: Attachment
			JointAttachment.CFrame = Motor.C1
			JointAttachment.Name = Part0.Name .. "JointAttachment"
			JointAttachment.Parent = Part1
		end
	end
end

function CCDIKController.commandBarSetupRigAttachments(Model: Model)
	local Descendants: { Instance } = Model:GetDescendants()

	for Index = 1, #Descendants do
		local Object: Instance = Descendants[Index]

		if Object:IsA("Motor6D") then
			local Motor: Motor6D = Object
			local Motor6DName: string = Motor.Name
			local Part0: BasePart = Motor.Part0 :: BasePart
			local Part1: BasePart = Motor.Part1 :: BasePart

			local AxisAttachment: Attachment = InstanceNew("Attachment") :: Attachment
			AxisAttachment.CFrame = Motor.C0
			AxisAttachment.Name = Motor6DName .. "RigAttachment"
			AxisAttachment.Parent = Part0

			local JointAttachment: Attachment = InstanceNew("Attachment") :: Attachment
			JointAttachment.CFrame = Motor.C1
			JointAttachment.Name = Motor6DName .. "RigAttachment"
			JointAttachment.Parent = Part1
		end
	end
end

function CCDIKController:Destroy()
	if self._Connections then
		for Index = 1, #self._Connections do
			local Connection: RBXScriptConnection? = self._Connections[Index]

			if Connection then
				pcall(function()
					Connection:Disconnect()
				end)

				self._Connections[Index] = nil
			end
		end
	end

	if self.Maid then
		self.Maid:DoCleaning()
	end

	self = nil
end

return CCDIKController
