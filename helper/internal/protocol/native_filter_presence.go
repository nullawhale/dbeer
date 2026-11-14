package protocol

// HasNativeValue covers both wire representations without normalizing an
// invalid list into an apparently unfiltered or legacy request.
func (request CatalogRequest) HasNativeValue() bool {
	if request.FilterExpression != nil && request.FilterExpression.HasNativeValue() {
		return true
	}
	for _, filter := range request.Filters {
		if filter.NativeValue != nil {
			return true
		}
	}
	return false
}

// HasNativeValue lets unsupported adapters reject typed operands before any
// catalog or data read. Validity and resource bounds remain separate checks.
func (e CatalogFilterExpression) HasNativeValue() bool {
	if e.Condition != nil && e.Condition.NativeValue != nil {
		return true
	}
	for _, child := range e.Children {
		if child.HasNativeValue() {
			return true
		}
	}
	return false
}
