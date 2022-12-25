import smartpy as sp

class PaymentCapturer(sp.Contract):
    def __init__(self, admin_address, treasury_address, refund_manager_address):
        self.init_type(sp.TRecord(admin_address = sp.TAddress, refund_manager_address = sp.TAddress, treasury_address = sp.TAddress))
        self.init(admin_address=admin_address,
                  treasury_address=treasury_address,
                  refund_manager_address=refund_manager_address
                  )

    @sp.entry_point
    def pay(self, metadata):
        sp.set_type(metadata, sp.TString)
        prepared_metadata = (metadata, sp.amount, sp.source)
        sp.emit(prepared_metadata, with_type=True, tag="PAY")

    @sp.entry_point
    def refund(self, metadata, amount, buyer):
        sp.set_type(metadata, sp.TString)
        sp.verify_equal(self.data.refund_manager_address, sp.source, "Refund not authorised.")
        sp.verify(sp.balance >= amount, "Contract does not have enough balance.")
        sp.send(buyer, amount, "Failed to refund.")
        sp.emit(metadata, with_type=True, tag="REFUND")

    @sp.entry_point
    def withdraw(self):
        sp.verify_equal(self.data.admin_address, sp.source, "Withdraw not authorised.")
        sp.send(self.data.treasury_address, sp.balance, "Could not withdraw.")

    @sp.entry_point
    def withdrawAmount(self, amount):
        sp.verify_equal(self.data.admin_address, sp.source, "Withdraw not authorised.")
        sp.send(self.data.treasury_address, amount, "Could not withdraw.")

    @sp.add_test(name="PaymentsCapturer")
    def test():
        admin = sp.test_account("admin")
        treasury = sp.test_account("treasury")
        refund_manager = sp.test_account("refund_manager")
        user = sp.test_account("user")
        
        r = PaymentCapturer(admin.address, treasury.address, refund_manager.address)
        scenario = sp.test_scenario()
        scenario.h1("Payments Capturer")
        scenario += r

        scenario.h2("Regular flow")
        scenario.h3("Pay")
        pay_amount = sp.tez(100)
        pay_metadata = "ok"
        scenario += r.pay(pay_metadata).run(source=user.address, amount=pay_amount, valid=True)
        scenario.verify_equal(r.balance, pay_amount)

        scenario.h3("Unauthorised Refund")
        refund_amount = sp.tez(40)
        refund_metadata = "refund"
        user = sp.test_account("user")
        scenario += r.refund(metadata=refund_metadata, amount=refund_amount, buyer=user.address).run(source=user.address, valid=False)
        scenario.verify_equal(r.balance, pay_amount)
        
        scenario.h3("Authorised Refund")
        refund_amount = sp.tez(40)
        refund_metadata = "refund"
        user = sp.test_account("user")
        scenario += r.refund(metadata=refund_metadata, amount=refund_amount, buyer=user.address).run(source=refund_manager.address, valid=True)
        expected_contract_balance = pay_amount - refund_amount
        scenario.verify_equal(r.balance, expected_contract_balance)

        scenario.h3("Unauthorised WithdrawAmount")
        amount = sp.tez(10)
        scenario += r.withdrawAmount(amount).run(source=user.address, valid=False)
        scenario.verify_equal(r.balance, expected_contract_balance)
        
        scenario.h3("Authorised WithdrawAmount")
        scenario += r.withdrawAmount(amount).run(source=admin.address, valid=True)
        scenario.verify_equal(r.balance, expected_contract_balance - amount)
        
        scenario.h3("Unauthorised Withdraw")
        scenario += r.withdraw().run(source=user.address, valid=False)
        scenario.verify_equal(r.balance, expected_contract_balance - amount)
        
        scenario.h3("Authorised Withdraw")
        scenario += r.withdraw().run(source=admin.address, valid=True)
        scenario.verify_equal(r.balance, sp.tez(0))

sp.add_compilation_target("my_contract_compiled", PaymentCapturer(admin_address=sp.address("tz1NHjoiSpRj8gzJbAxQSyTfiPwfxcRnnVfn"), treasury_address=sp.address("tz1NHjoiSpRj8gzJbAxQSyTfiPwfxcRnnVfn"), refund_manager_address=sp.address("tz1NHjoiSpRj8gzJbAxQSyTfiPwfxcRnnVfn")))
