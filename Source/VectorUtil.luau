--[[
	VectorUtil.ClampMagnitude(Vector: Vector3, MaxMagnitude: number): Vector3
	VectorUtil.AngleBetween(Vector1: Vector3, Vector2: Vector3): number
	VectorUtil.AngleBetweenSigned(Vector1: Vector3, Vector2: Vector3, AxisVector: Vector3): number
	VectorUtil.SquaredMagnitude(Vector: Vector3): number
--]]

local VectorUtil = {}

--- Clamps the magnitude of a vector so it is only a certain length.
function VectorUtil.ClampMagnitude(Vector: Vector3, MaxMagnitude: number): Vector3
	if Vector.Magnitude > MaxMagnitude then
		return Vector.Unit * MaxMagnitude
	end

	return Vector
end

--- Finds the angle (in radians) between two vectors.
function VectorUtil.AngleBetween(Vector1: Vector3, Vector2: Vector3): number
	-- Clamping the dot product to [-1, 1] prevents NaN errors due to floating point precision
	return math.acos(math.clamp(Vector1.Unit:Dot(Vector2.Unit), -1, 1))
end

--- Same as AngleBetween, but returns a signed value based on the axis.
function VectorUtil.AngleBetweenSigned(Vector1: Vector3, Vector2: Vector3, AxisVector: Vector3): number
	local Angle = VectorUtil.AngleBetween(Vector1, Vector2)
	local Sign = math.sign(AxisVector:Dot(Vector1:Cross(Vector2)))

	return Angle * Sign
end

--- Returns the squared magnitude of the vector.
-- Useful for performance when comparing distances as it avoids a square root calculation.
function VectorUtil.SquaredMagnitude(Vector: Vector3): number
	-- In Luau, Vector3.Magnitude ^ 2 is often sufficient,
	-- but manual calculation is the most direct "hard" math approach:
	return (Vector.X * Vector.X) + (Vector.Y * Vector.Y) + (Vector.Z * Vector.Z)
end

return VectorUtil
