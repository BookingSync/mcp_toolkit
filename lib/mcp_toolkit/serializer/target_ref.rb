# frozen_string_literal: true

# Minimal object satisfying the gem's `association.serializer.model_class`
# probe (ResourceSchema's target-resource resolution): carries the model an
# association resolves to. Pair with AssociationDescriptor when adapting a
# host serializer framework.
McpToolkit::Serializer::TargetRef = Struct.new(:model_class)
