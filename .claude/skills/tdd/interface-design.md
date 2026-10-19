# Interface Design for Testability

Good interfaces make testing natural:

1. **Dependency injection**: take collaborators as parameters (`processOrder(order, paymentGateway)`) rather than constructing them inside.

2. **Pure functions**: return a result (`calculateDiscount(cart): Discount`) rather than mutating inputs or producing side effects.

3. **Small surface area**
   - Fewer methods = fewer tests needed
   - Fewer params = simpler test setup
