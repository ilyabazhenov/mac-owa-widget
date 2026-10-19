import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import OWAWidget

/// Pictures pasted into an outgoing message: the editor's text, the HTML body and the EWS
/// requests that attach them.
@MainActor
final class MailInlineImagesTests: XCTestCase {
    private func png(width: Int = 4, height: Int = 3, alpha: Bool = true) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private func image(_ id: String) -> MailInlineImage {
        MailInlineImage(contentID: id, name: "\(id).png", contentType: "image/png", data: png())
    }

    func testBodyHTMLPutsPicturesWhereTheMarksAre() {
        let html = OWAMailPayloads.outgoingBodyHTML(
            plainText: "Look <here>:\n\u{FFFC}\nand \u{FFFC} done\u{FFFC}",
            inlineImages: [image("a@x"), image("b\"@x")]
        )
        XCTAssertTrue(html.contains(#"Look &lt;here&gt;:<br><img src="cid:a@x" alt="a@x.png" style="max-width: 100%;"><br>and <img src="cid:b&quot;@x""#))
        XCTAssertTrue(html.contains(" done</div>"), "a mark with no picture left is dropped")
        XCTAssertFalse(html.contains("\u{FFFC}"))
    }

    func testBodyHTMLWithoutPicturesIsUnchanged() {
        XCTAssertEqual(
            OWAMailPayloads.outgoingBodyHTML(plainText: "a\nb"),
            OWAMailPayloads.outgoingBodyHTML(plainText: "a\nb", inlineImages: [])
        )
        XCTAssertTrue(OWAMailPayloads.outgoingBodyHTML(plainText: "\u{FFFC}").contains("<div style=\"font-family: Calibri, Arial, sans-serif; font-size: 11pt;\"><br></div>"))
    }

    func testCreateAttachmentSOAPAttachesInlineFiles() {
        let data = Data([1, 2, 3])
        let soap = OWAMailPayloads.createInlineAttachmentsSOAP(
            parent: MailItemRef(id: "D&1", changeKey: nil),
            images: [MailInlineImage(contentID: "c1@owawidget", name: "a<b>.png", contentType: "image/png", data: data)]
        )
        XCTAssertTrue(soap.contains(#"<m:ParentItemId Id="D&amp;1"/>"#))
        XCTAssertTrue(soap.contains("<t:Name>a&lt;b&gt;.png</t:Name><t:ContentType>image/png</t:ContentType><t:ContentId>c1@owawidget</t:ContentId><t:IsInline>true</t:IsInline><t:Content>\(data.base64EncodedString())</t:Content>"))
    }

    func testAttachmentResponseGivesTheDraftsNewChangeKey() {
        let soap = """
        <m:CreateAttachmentResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Attachments>
        <t:FileAttachment><t:AttachmentId Id="A1" RootItemId="DRAFT" RootItemChangeKey="CK1"/></t:FileAttachment>
        <t:FileAttachment><t:AttachmentId Id="A2" RootItemId="DRAFT" RootItemChangeKey="CK2"/></t:FileAttachment>
        </m:Attachments></m:CreateAttachmentResponseMessage>
        """
        XCTAssertEqual(OWAMailParsers.attachmentRootItemRef(fromSOAP: soap), MailItemRef(id: "DRAFT", changeKey: "CK2"))
        XCTAssertNil(OWAMailParsers.attachmentRootItemRef(fromSOAP: "<m:Attachments/>"))
    }

    func testEditorContentRoundTrips() {
        let images = [image("a"), image("b")]
        let text = "one \u{FFFC}\ntwo\u{FFFC}"
        let attributed = MailComposeBodyEditor.attributedString(text: text, images: images)
        let content = MailComposeBodyEditor.content(of: attributed)
        XCTAssertEqual(content.text, text)
        XCTAssertEqual(content.images, images)
    }

    func testEditorDropsMarksWithoutPictures() {
        let attributed = MailComposeBodyEditor.attributedString(text: "a\u{FFFC}b\u{FFFC}", images: [image("x")])
        let content = MailComposeBodyEditor.content(of: attributed)
        XCTAssertEqual(content.text, "a\u{FFFC}b")
        XCTAssertEqual(content.images.map(\.contentID), ["x"])
    }

    func testPastedTIFFGoesAsPNG() throws {
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: png())?.tiffRepresentation)
        let pasted = try XCTUnwrap(MailPastedImages.image(data: tiff, type: .tiff, baseName: "image"))
        XCTAssertEqual(pasted.contentType, "image/png")
        XCTAssertEqual(pasted.name, "image.png")
        XCTAssertNotNil(NSBitmapImageRep(data: pasted.data))
    }

    func testRichTextKeepsPicturesAndDropsStyles() throws {
        let source = NSMutableAttributedString(string: "Hi ", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        let wrapper = FileWrapper(regularFileWithContents: png())
        wrapper.preferredFilename = "chart.png"
        source.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        source.append(NSAttributedString(string: " there"))
        let content = try XCTUnwrap(MailPastedImages.plainWithPictures(source))
        let parsed = MailComposeBodyEditor.content(of: content)
        XCTAssertEqual(parsed.text, "Hi \u{FFFC} there")
        XCTAssertEqual(parsed.images.map(\.name), ["chart.png"])
        XCTAssertNil(MailPastedImages.plainWithPictures(NSAttributedString(string: "plain")))
    }
}
