(grammar_rule
 rule_def: (lhs rule_name: (nonterminal) @name)) @definition.class

(grammar_rule
  action_def: (named_action (action_name) @name)) @definition.interface

(ditto_rule
  action_def: (named_action (action_name) @name)) @definition.interface

(grammar_rule
  (rhs rule_name: (nonterminal) @name)) @reference.class

(ditto_rule
  (rhs rule_name: (nonterminal) @name)) @reference.class

(grammar_rule
  (rhs rule_name: (terminal) @name)) @reference.enum

(grammar_rule
  (rhs rule_name: (multiterminal (terminal) @name))) @reference.enum

(ditto_rule
  (rhs rule_name: (terminal) @name)) @reference.enum

(ditto_rule
  (rhs rule_name: (multiterminal (terminal) @name))) @reference.enum

(directive
  (arg_directive_name)
  (nonterminal) @name
  (multiterminal)) @definition.constant

(directive
  (arg_directive_name)
  (nonterminal) @name
  [(code_block)
   (string)
   (number)
   (identifier)]) @reference.class

(directive
  (token_directive_name)
  (nonterminal) @name) @reference.class

(directive
  (terminal) @name) @reference.enum

(directive
  (multiterminal (terminal) @name)) @reference.enum

(directive
  action_impl: (named_action (action_name) @name)) @reference.implementation
