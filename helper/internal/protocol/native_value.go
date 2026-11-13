package protocol

import "dbeer/helper/internal/nativevalue"

const NativeResultValuesCapability = nativevalue.NativeResultValuesCapability
const NativeResultValuesFormat = nativevalue.NativeResultValuesFormat
const MaxNativeValueDepth = nativevalue.MaxNativeValueDepth
const MaxNativeValueNodes = nativevalue.MaxNativeValueNodes
const MaxNativeValueBytes = nativevalue.MaxNativeValueBytes

type NativeValue = nativevalue.NativeValue
type NativeEntry = nativevalue.NativeEntry
type NativeMatrixBudget = nativevalue.NativeMatrixBudget

func NativeScalar(kind, value string) NativeValue { return nativevalue.NativeScalar(kind, value) }
func NativeBinary(value []byte) NativeValue       { return nativevalue.NativeBinary(value) }
func NativeFloat32(value float32) NativeValue     { return nativevalue.NativeFloat32(value) }
func NativeFloat64(value float64) NativeValue     { return nativevalue.NativeFloat64(value) }
func NativeMatrixValid(values [][]NativeValue, rows, columns int) bool {
	return nativevalue.NativeMatrixValid(values, rows, columns)
}
