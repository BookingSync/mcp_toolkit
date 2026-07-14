# frozen_string_literal: true

# The association shape the gem reads off a serializer's
# `declared_associations` (ResourceSchema's relationship entries,
# FieldSelection's valid `fields` names). A host adapting its OWN serializer
# framework builds these rather than re-deriving the duck-type by hand:
# `links_key` / `type` / `polymorphic` / `name`, plus an optional `serializer`
# responding to `model_class` (see TargetRef) so the target resource resolves.
McpToolkit::Serializer::AssociationDescriptor = Struct.new(
  :name, :type, :polymorphic, :links_key, :serializer, keyword_init: true
)
